# Everything here is a shell away already; the targets are names for it.

.PHONY: test font install

# Status line output in a throwaway $HOME, and the code point layout agreeing
# between statusline.sh and fonts/build.swift.
test:
	tests/run.sh

# Downloads the source pictures on first run and checks their SHA-256.
font:
	swift fonts/build.swift fonts/StatuslineIcons.otf

install:
	./install.sh
