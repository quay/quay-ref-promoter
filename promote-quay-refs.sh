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

if [ ${#REPO_LIST[@]} -eq 0 ]; then
    gum style --foreground 196 "No active deployments found (all are pinned to main/master or disabled)!"
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
gum style --foreground 82 --bold "Done! You can now review and commit the changes."
