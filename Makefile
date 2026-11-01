ID := io.github.arbabmujtaba.omaecosystem
DEST := $(HOME)/.config/omarchy/plugins/$(ID)
FILES := manifest.json BarWidget.qml Dock.qml bin/omaecosystem README.md LICENSE

.PHONY: all install enable uninstall check

all:
	@echo "targets: install, enable, uninstall, check"

check:
	/usr/bin/python3 -m py_compile bin/omaecosystem && rm -rf bin/__pycache__
	jq empty manifest.json

install: check
	install -d $(DEST)/bin
	for f in $(FILES); do install -m644 $$f $(DEST)/$$f; done
	chmod 755 $(DEST)/bin/omaecosystem
	-omarchy-shell shell rescanPlugins >/dev/null 2>&1
	@echo "installed to $(DEST)"

enable: install
	omarchy plugin enable $(ID)

uninstall:
	-omarchy plugin disable $(ID)
	rm -rf $(DEST)
	-omarchy-shell shell rescanPlugins >/dev/null 2>&1
