#!/usr/bin/env bash

set -e

APP_INTERFACE_DIR="${1:-$APP_INTERFACE_PATH}"

if [ -z "$APP_INTERFACE_DIR" ]; then
    APP_INTERFACE_DIR="$(pwd)"
fi

if [ ! -d "$APP_INTERFACE_DIR" ]; then
    echo "Error: Directory does not exist: $APP_INTERFACE_DIR"
    exit 1
fi

QUAYIO_SAAS_DIR="$APP_INTERFACE_DIR/data/services/quayio/saas"
REGISTRY_PROXY_SAAS_DIR="$APP_INTERFACE_DIR/data/services/registry-proxy/saas"

if [ ! -d "$QUAYIO_SAAS_DIR" ] && [ ! -d "$REGISTRY_PROXY_SAAS_DIR" ]; then
    echo "Error: Could not find quayio or registry-proxy saas directories in $APP_INTERFACE_DIR"
    echo ""
    echo "Usage: $0 [APP_INTERFACE_PATH]"
    echo "  or set APP_INTERFACE_PATH environment variable"
    echo ""
    echo "Expected directory structure:"
    echo "  $APP_INTERFACE_DIR/data/services/quayio/saas/"
    echo "  $APP_INTERFACE_DIR/data/services/registry-proxy/saas/"
    exit 1
fi

if [ "$(uname)" = "Darwin" ]; then
    SED_OPT=".bk"
fi

if ! command -v gum &> /dev/null; then
    echo "Error: gum is not installed. Please install it from https://github.com/charmbracelet/gum"
    exit 1
fi

if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed. Please install it to parse YAML files."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install it to parse JSON responses."
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed. Please install it to check for migrations."
    exit 1
fi

if ! command -v git &> /dev/null; then
    echo "Error: git is not installed. Please install it to commit changes."
    exit 1
fi

gum style \
    --foreground 212 --border-foreground 212 --border double \
    --align center --width 50 --margin "1 2" --padding "2 4" \
    'Quay.io Production Promoter'

echo ""
gum style --foreground 33 "Promote git refs to production namespaces."
gum style --foreground 240 "Using: $APP_INTERFACE_DIR"
echo ""

SERVICE=$(gum choose \
    --header "Select service:" \
    "quayio" \
    "registry-proxy" \
    "both")

declare -a SAAS_DIRS=()

case $SERVICE in
    "quayio")
        if [ ! -d "$QUAYIO_SAAS_DIR" ]; then
            gum style --foreground 196 "Error: quayio saas directory not found: $QUAYIO_SAAS_DIR"
            exit 1
        fi
        SAAS_DIRS+=("$QUAYIO_SAAS_DIR")
        ;;
    "registry-proxy")
        if [ ! -d "$REGISTRY_PROXY_SAAS_DIR" ]; then
            gum style --foreground 196 "Error: registry-proxy saas directory not found: $REGISTRY_PROXY_SAAS_DIR"
            exit 1
        fi
        SAAS_DIRS+=("$REGISTRY_PROXY_SAAS_DIR")
        ;;
    "both")
        if [ -d "$QUAYIO_SAAS_DIR" ]; then
            SAAS_DIRS+=("$QUAYIO_SAAS_DIR")
        fi
        if [ -d "$REGISTRY_PROXY_SAAS_DIR" ]; then
            SAAS_DIRS+=("$REGISTRY_PROXY_SAAS_DIR")
        fi
        if [ ${#SAAS_DIRS[@]} -eq 0 ]; then
            gum style --foreground 196 "Error: No saas directories found"
            exit 1
        fi
        ;;
esac

echo ""
gum style --foreground 105 "Scanning for repositories and deployments..."

declare -A DEPLOYMENT_MAP
declare -a REPO_LIST=()
declare -A REPO_COUNT=()
declare -a AUTO_PROMOTED_TARGETS=()

for SAAS_DIR in "${SAAS_DIRS[@]}"; do
    while IFS= read -r SAAS_FILE; do
        RESOURCE_TEMPLATES=$(yq eval '.resourceTemplates[] | .name' "$SAAS_FILE" 2>/dev/null || echo "")

        if [ -z "$RESOURCE_TEMPLATES" ]; then
            continue
        fi

        while IFS= read -r TEMPLATE_NAME; do
            TEMPLATE_INDEX=$(yq eval ".resourceTemplates | to_entries | .[] | select(.value.name == \"$TEMPLATE_NAME\") | .key" "$SAAS_FILE")

            REPO_URL=$(yq eval ".resourceTemplates[$TEMPLATE_INDEX].url" "$SAAS_FILE" 2>/dev/null || echo "")

            if [ -z "$REPO_URL" ] || [ "$REPO_URL" = "null" ]; then
                continue
            fi

            TARGETS=$(yq eval ".resourceTemplates[$TEMPLATE_INDEX].targets | length" "$SAAS_FILE" 2>/dev/null || echo "0")

            for ((i=0; i<$TARGETS; i++)); do
                NS_REF=$(yq eval ".resourceTemplates[$TEMPLATE_INDEX].targets[$i].namespace.\$ref" "$SAAS_FILE" 2>/dev/null || echo "")
                REF=$(yq eval ".resourceTemplates[$TEMPLATE_INDEX].targets[$i].ref" "$SAAS_FILE" 2>/dev/null || echo "")
                DISABLE=$(yq eval ".resourceTemplates[$TEMPLATE_INDEX].targets[$i].disable" "$SAAS_FILE" 2>/dev/null || echo "false")
                DELETE=$(yq eval ".resourceTemplates[$TEMPLATE_INDEX].targets[$i].delete" "$SAAS_FILE" 2>/dev/null || echo "false")
                PROMOTION_AUTO=$(yq eval ".resourceTemplates[$TEMPLATE_INDEX].targets[$i].promotion.auto" "$SAAS_FILE" 2>/dev/null || echo "false")

                if [ "$PROMOTION_AUTO" = "true" ]; then
                    NS_CLEAN=$(echo "$NS_REF" | sed 's|^/||')
                    AUTO_PROMOTED_TARGETS+=("$(basename "$SAAS_FILE") → $TEMPLATE_NAME → $NS_CLEAN")
                    continue
                fi

                if [ -n "$NS_REF" ] && [ "$NS_REF" != "null" ] && [ -n "$REF" ] && [ "$REF" != "null" ] && [ "$DISABLE" != "true" ] && [ "$DELETE" != "true" ] && [ "$REF" != "main" ] && [ "$REF" != "master" ]; then
                    NS_CLEAN=$(echo "$NS_REF" | sed 's|^/||')

                    KEY="${REPO_URL}|${NS_CLEAN}|${SAAS_FILE}|${TEMPLATE_NAME}|${i}"
                    DEPLOYMENT_MAP["$KEY"]="$REF"

                    if [[ ! " ${REPO_LIST[@]} " =~ " ${REPO_URL} " ]]; then
                        REPO_LIST+=("$REPO_URL")
                        REPO_COUNT["$REPO_URL"]=1
                    else
                        ((REPO_COUNT["$REPO_URL"]++))
                    fi
                fi
            done
        done <<< "$RESOURCE_TEMPLATES"
    done < <(find "$SAAS_DIR" -name "*.yaml" -o -name "*.yml")
done

if [ ${#AUTO_PROMOTED_TARGETS[@]} -gt 0 ]; then
    echo ""
    gum style --foreground 226 "Skipped ${#AUTO_PROMOTED_TARGETS[@]} auto-promoted target(s) (promotion.auto: true):"
    for AUTO_TARGET in "${AUTO_PROMOTED_TARGETS[@]}"; do
        gum style --foreground 240 "  • $AUTO_TARGET"
    done
fi

if [ ${#REPO_LIST[@]} -eq 0 ]; then
    gum style --foreground 196 "No active deployments found (all are pinned to main/master, disabled, or auto-promoted)!"
    exit 1
fi

IFS=$'\n' SORTED_REPOS=($(sort <<<"${REPO_LIST[*]}"))
unset IFS

declare -a REPO_DISPLAY=()
for REPO in "${SORTED_REPOS[@]}"; do
    COUNT="${REPO_COUNT[$REPO]}"
    REPO_DISPLAY+=("$REPO ($COUNT deployments)")
done

echo ""
SELECTED_REPO_DISPLAY=$(printf '%s\n' "${REPO_DISPLAY[@]}" | gum choose \
    --header "Select repository to promote:")

if [ -z "$SELECTED_REPO_DISPLAY" ]; then
    gum style --foreground 196 "No repository selected. Exiting."
    exit 0
fi

SELECTED_REPO=$(echo "$SELECTED_REPO_DISPLAY" | sed 's/ ([0-9]* deployments)$//')

echo ""
gum style --foreground 105 "Finding deployments for: $SELECTED_REPO"
echo ""

declare -a TARGETS_TO_UPDATE=()
declare -A TARGET_DISPLAY=()

for KEY in "${!DEPLOYMENT_MAP[@]}"; do
    IFS='|' read -r REPO_URL NS SAAS_FILE TEMPLATE_NAME TARGET_INDEX <<< "$KEY"

    if [ "$REPO_URL" = "$SELECTED_REPO" ]; then
        CURRENT_REF="${DEPLOYMENT_MAP[$KEY]}"
        SAAS_BASENAME=$(basename "$SAAS_FILE")
        DISPLAY="$SAAS_BASENAME → $TEMPLATE_NAME → $NS (current: ${CURRENT_REF:0:12})"
        TARGET_DISPLAY["$KEY"]="$DISPLAY"
        TARGETS_TO_UPDATE+=("$KEY")
    fi
done

if [ ${#TARGETS_TO_UPDATE[@]} -eq 0 ]; then
    gum style --foreground 196 "No deployments found for this repository!"
    exit 1
fi

declare -a DISPLAY_OPTIONS=()
for KEY in "${TARGETS_TO_UPDATE[@]}"; do
    DISPLAY_OPTIONS+=("${TARGET_DISPLAY[$KEY]}")
done

IFS=$'\n' SORTED_DISPLAY=($(sort <<<"${DISPLAY_OPTIONS[*]}"))
unset IFS

SELECTED_TARGETS=$(printf '%s\n' "${SORTED_DISPLAY[@]}" | gum choose \
    --no-limit \
    --header "Select deployments to update (space to select, enter to confirm):" \
    --height 15)

if [ -z "$SELECTED_TARGETS" ]; then
    gum style --foreground 196 "No deployments selected. Exiting."
    exit 0
fi

echo ""
NEW_REF=$(gum input \
    --placeholder "Enter the new git ref for $SELECTED_REPO" \
    --prompt "New ref: " \
    --width 70)

if [ -z "$NEW_REF" ]; then
    gum style --foreground 196 "No ref provided. Exiting."
    exit 0
fi

check_migrations() {
    local old_ref="$1"
    local new_ref="$2"
    local repo_owner="quay"
    local repo_name="quay"

    local compare_result
    compare_result=$(curl -s "https://api.github.com/repos/${repo_owner}/${repo_name}/compare/${old_ref}...${new_ref}" 2>/dev/null)

    if [ -z "$compare_result" ]; then
        return 0
    fi

    local migration_files
    migration_files=$(echo "$compare_result" | jq -r '.files[]?.filename // empty' 2>/dev/null | grep "^data/migrations/" || true)

    if [ -n "$migration_files" ]; then
        echo "$migration_files"
    fi

    return 0
}

HAS_MIGRATIONS=false
MIGRATION_FILES_LIST=""

if [[ "$SELECTED_REPO" == *"github.com/quay/quay"* ]]; then
    echo ""
    gum style --foreground 226 "Checking for database migrations..."

    declare -a OLD_REFS=()
    while IFS= read -r SELECTED_DISPLAY; do
        for KEY in "${!TARGET_DISPLAY[@]}"; do
            if [ "${TARGET_DISPLAY[$KEY]}" = "$SELECTED_DISPLAY" ]; then
                OLD_REF="${DEPLOYMENT_MAP[$KEY]}"
                if [[ ! " ${OLD_REFS[@]} " =~ " ${OLD_REF} " ]]; then
                    OLD_REFS+=("$OLD_REF")
                fi
            fi
        done
    done <<< "$SELECTED_TARGETS"

    MIGRATIONS_FOUND=""
    for OLD_REF in "${OLD_REFS[@]}"; do
        MIGRATION_FILES=$(check_migrations "$OLD_REF" "$NEW_REF")
        if [ -n "$MIGRATION_FILES" ]; then
            if [ -z "$MIGRATIONS_FOUND" ]; then
                MIGRATIONS_FOUND="$MIGRATION_FILES"
            else
                MIGRATIONS_FOUND="$MIGRATIONS_FOUND"$'\n'"$MIGRATION_FILES"
            fi
        fi
    done

    MIGRATIONS_FOUND=$(echo "$MIGRATIONS_FOUND" | sort -u | grep -v '^$' || true)

    if [ -n "$MIGRATIONS_FOUND" ]; then
        HAS_MIGRATIONS=true
        MIGRATION_FILES_LIST="$MIGRATIONS_FOUND"
        echo ""
        gum style --foreground 196 --bold "⚠️  DATABASE MIGRATIONS DETECTED ⚠️"
        echo ""
        gum style --foreground 226 "The following migration files were found between the old and new refs:"
        echo ""
        echo "$MIGRATIONS_FOUND" | while read -r file; do
            gum style --foreground 214 "  • $file"
        done
        echo ""
        gum style --foreground 226 "Please ensure database migrations are applied before deploying!"
        gum style --foreground 240 "See: https://github.com/quay/quay/tree/master/data/migrations"
        echo ""
        gum confirm "Continue with promotion despite migrations?" || exit 0
    else
        gum style --foreground 82 "✓ No new database migrations detected."
    fi
fi

echo ""
gum confirm "Update selected deployments to ref: $NEW_REF?" || exit 0

declare -a UPDATED_FILES=()
declare -A FILE_SET=()

while IFS= read -r SELECTED_DISPLAY; do
    for KEY in "${!TARGET_DISPLAY[@]}"; do
        if [ "${TARGET_DISPLAY[$KEY]}" = "$SELECTED_DISPLAY" ]; then
            IFS='|' read -r REPO_URL NAMESPACE SAAS_FILE TEMPLATE_NAME TARGET_INDEX <<< "$KEY"

            OLD_REF="${DEPLOYMENT_MAP[$KEY]}"

            echo ""
            gum style --foreground 105 "Updating: $(basename "$SAAS_FILE") → $TEMPLATE_NAME → $NAMESPACE"

            TEMP_FILE=$(mktemp)
            awk -v old_ref="$OLD_REF" -v new_ref="$NEW_REF" -v ns_ref="$NAMESPACE" '
            BEGIN { in_target = 0; found_ns = 0 }
            {
                if ($0 ~ /namespace:/) {
                    in_target = 1
                    found_ns = 0
                }
                if (in_target && $0 ~ ns_ref) {
                    found_ns = 1
                }
                if (found_ns && $0 ~ /ref:/ && $0 ~ old_ref) {
                    gsub(old_ref, new_ref)
                    found_ns = 0
                    in_target = 0
                }
                print
            }
            ' "$SAAS_FILE" > "$TEMP_FILE"

            mv "$TEMP_FILE" "$SAAS_FILE"

            FILE_SET["$SAAS_FILE"]=1

            gum style --foreground 82 "  ✓ Updated: $OLD_REF → $NEW_REF"
        fi
    done
done <<< "$SELECTED_TARGETS"

for FILE in "${!FILE_SET[@]}"; do
    UPDATED_FILES+=("$FILE")
done

if [ ${#UPDATED_FILES[@]} -eq 0 ]; then
    echo ""
    gum style --foreground 226 "No files were updated."
    exit 0
fi

echo ""
gum style --foreground 82 --bold "Updated ${#UPDATED_FILES[@]} file(s):"
printf '%s\n' "${UPDATED_FILES[@]}" | sed 's/^/  - /'

echo ""
if gum confirm "Would you like to commit these changes?"; then
    REPO_SHORT=$(echo "$SELECTED_REPO" | sed 's|.*github.com/||' | sed 's|\.git$||')
    REF_SHORT="${NEW_REF:0:12}"

    if [ "$HAS_MIGRATIONS" = true ]; then
        COMMIT_TYPE="chore(deploy)!:"
        COMMIT_SUBJECT="promote ${REPO_SHORT} to ${REF_SHORT}"

        MIGRATION_COUNT=$(echo "$MIGRATION_FILES_LIST" | wc -l | tr -d ' ')
        BREAKING_FOOTER="BREAKING CHANGE: This promotion includes ${MIGRATION_COUNT} database migration(s).
Ensure migrations are applied before deployment.

Migration files:
$(echo "$MIGRATION_FILES_LIST" | sed 's/^/- /')"

        COMMIT_MSG="${COMMIT_TYPE} ${COMMIT_SUBJECT}

${BREAKING_FOOTER}"
    else
        COMMIT_TYPE="chore(deploy):"
        COMMIT_SUBJECT="promote ${REPO_SHORT} to ${REF_SHORT}"
        COMMIT_MSG="${COMMIT_TYPE} ${COMMIT_SUBJECT}"
    fi

    echo ""
    gum style --foreground 105 "Proposed commit message:"
    echo ""
    gum style --foreground 240 "$COMMIT_MSG"
    echo ""

    EDIT_CHOICE=$(gum choose \
        --header "How would you like to proceed?" \
        "Use this message" \
        "Edit message" \
        "Cancel commit")

    case "$EDIT_CHOICE" in
        "Use this message")
            ;;
        "Edit message")
            COMMIT_MSG=$(gum write --placeholder "Edit commit message..." --value "$COMMIT_MSG" --width 80 --height 15)
            if [ -z "$COMMIT_MSG" ]; then
                gum style --foreground 196 "Empty commit message. Commit cancelled."
                exit 0
            fi
            ;;
        "Cancel commit")
            gum style --foreground 226 "Commit cancelled. Files have been updated but not committed."
            exit 0
            ;;
    esac

    git -C "$APP_INTERFACE_DIR" add "${UPDATED_FILES[@]}"
    git -C "$APP_INTERFACE_DIR" commit -m "$COMMIT_MSG"

    echo ""
    gum style --foreground 82 --bold "Changes committed successfully!"

    if [ "$HAS_MIGRATIONS" = true ]; then
        echo ""
        gum style --foreground 226 "Remember: Database migrations must be applied before deployment!"
    fi
else
    echo ""
    gum style --foreground 82 --bold "Done! You can review and commit the changes manually."
fi
