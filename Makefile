SCRIPT_NAME := promote-quay-refs.sh
INSTALL_DIR := $(HOME)/.local/bin
INSTALLED_SCRIPT := $(INSTALL_DIR)/$(SCRIPT_NAME)

.PHONY: install uninstall help

help:
	@echo "quay-ref-promoter"
	@echo ""
	@echo "Targets:"
	@echo "  make install    - Install script to ~/.local/bin"
	@echo "  make uninstall  - Remove script from ~/.local/bin"
	@echo ""
	@echo "Environment Variables:"
	@echo "  APP_INTERFACE_PATH - Path to your app-interface repository"
	@echo ""
	@echo "Example usage after install:"
	@echo "  export APP_INTERFACE_PATH=/path/to/app-interface"
	@echo "  promote-quay-refs.sh"

install: $(INSTALL_DIR)
	@cp $(SCRIPT_NAME) $(INSTALLED_SCRIPT)
	@chmod +x $(INSTALLED_SCRIPT)
	@echo "Installed to $(INSTALLED_SCRIPT)"
	@echo ""
	@echo "Ensure ~/.local/bin is in your PATH:"
	@echo "  export PATH=\"\$$HOME/.local/bin:\$$PATH\""
	@echo ""
	@echo "Set APP_INTERFACE_PATH to your app-interface directory:"
	@echo "  export APP_INTERFACE_PATH=/path/to/app-interface"

$(INSTALL_DIR):
	@mkdir -p $(INSTALL_DIR)

uninstall:
	@rm -f $(INSTALLED_SCRIPT)
	@echo "Uninstalled $(INSTALLED_SCRIPT)"
