GOFLAGS := -tags load_wgnt_from_rsrc -ldflags="-H windowsgui -s -w" -trimpath -buildvcs=false -v
export GOOS := windows
export PATH := $(CURDIR)/.deps/go/bin:$(PATH)

VERSION := $(shell sed -n 's/^\s*Number\s*=\s*"\([0-9.]\+\)"$$/\1/p' version/version.go)
empty :=
space := $(empty) $(empty)
comma := ,
RCFLAGS := -DWIREGUARD_VERSION_ARRAY=$(subst $(space),$(comma),$(wordlist 1,4,$(subst .,$(space),$(VERSION)) 0 0 0 0)) -DWIREGUARD_VERSION_STR=$(VERSION) -O coff -c 65001

rwildcard=$(foreach d,$(filter-out .deps,$(wildcard $1*)),$(call rwildcard,$d/,$2) $(filter $(subst *,%,$2),$d))
SOURCE_FILES := $(call rwildcard,,*.go) .deps/go/prepared go.mod go.sum
RESOURCE_FILES := resources.rc version/version.go manifest.xml $(patsubst %.svg,%.ico,$(wildcard ui/icon/*.svg)) .deps/wintun/prepared

DEPLOYMENT_HOST ?= winvm
DEPLOYMENT_PATH ?= Desktop

all: amd64/amneziawg.exe x86/amneziawg.exe

define download =
.distfiles/$(1):
	mkdir -p .distfiles
	if ! curl -L#o $$@.unverified $(2); then rm -f $$@.unverified; exit 1; fi
	if ! echo "$(3)  $$@.unverified" | sha256sum -c; then rm -f $$@.unverified; exit 1; fi
	if ! mv $$@.unverified $$@; then rm -f $$@.unverified; exit 1; fi
endef

$(eval $(call download,go.tar.gz,https://go.dev/dl/go1.22.0.linux-amd64.tar.gz,f6c8a87aa03b92c4b0bf3d558e28ea03006eb29db78917daec5cfb6ec1046265))
$(eval $(call download,wintun.zip,https://www.wintun.net/builds/wintun-0.14.1.zip,07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51))

.deps/go/prepared: .distfiles/go.tar.gz
	mkdir -p .deps
	rm -rf .deps/go
	bsdtar -C .deps -xf .distfiles/go.tar.gz
	chmod -R +w .deps/go
	touch $@

.deps/wintun/prepared: .distfiles/wintun.zip
	mkdir -p .deps
	rm -rf .deps/wintun
	bsdtar -C .deps -xf .distfiles/wintun.zip
	touch $@

%.ico: %.svg
	convert -background none $< -define icon:auto-resize="256,192,128,96,64,48,40,32,24,20,16" -compress zip $@

resources_amd64.syso: $(RESOURCE_FILES)
	x86_64-w64-mingw32-windres $(RCFLAGS) -i $< -o $@

resources_386.syso: $(RESOURCE_FILES)
	i686-w64-mingw32-windres $(RCFLAGS) -i $< -o $@

resources_arm64.syso: $(RESOURCE_FILES)
	aarch64-w64-mingw32-windres $(RCFLAGS) -i $< -o $@

amd64/amneziawg.exe: export GOARCH := amd64
amd64/amneziawg.exe: amd64/wintun.dll resources_amd64.syso $(SOURCE_FILES)
	go build $(GOFLAGS) -o $@

x86/amneziawg.exe: export GOARCH := 386
x86/amneziawg.exe: x86/wintun.dll resources_386.syso $(SOURCE_FILES)
	go build $(GOFLAGS) -o $@

arm64/amneziawg.exe: export GOARCH := arm64
arm64/amneziawg.exe: resources_arm64.syso $(SOURCE_FILES)
	go build $(GOFLAGS) -o $@

amd64/wintun.dll:
	cp .deps/wintun/bin/amd64/wintun.dll $@

x86/wintun.dll:
	cp .deps/wintun/bin/x86/wintun.dll $@

remaster: export GOARCH := amd64
remaster: export GOPROXY := direct
remaster: .deps/go/prepared
	rm -f go.sum go.mod
	cp go.mod.master go.mod
	go get -d
	sed -i $(shell curl -L 'https://go.dev/dl/?mode=json&include=all' | jq -r '(".windows-amd64.zip",".linux-amd64.tar.gz") as $$suffix | .[0].files[] | select(.filename|endswith($$suffix)) | ("-e", "s/go[0-9][^ ]*\\\($$suffix)\\([ ,]\\)[a-f0-9]\\+/\(.filename)\\1\(.sha256)/") | @sh') Makefile build.bat

fmt: export GOARCH := amd64
fmt: .deps/go/prepared
	go fmt ./...

generate: export GOOS :=
generate: .deps/go/prepared
	go generate -mod=mod ./...

crowdin:
	find locales -maxdepth 1 -mindepth 1 -type d \! -name en -exec rm -rf {} +
	curl -Lo - https://crowdin.com/backend/download/project/wireguard.zip | bsdtar -C locales -x -f - --strip-components 2 wireguard-windows
	find locales -name messages.gotext.json -exec bash -c '[[ $$(jq ".messages | length" {}) -ne 0 ]] || rm -rf "$$(dirname {})"' \;
	@$(MAKE) --no-print-directory generate

deploy: amd64/amneziawg.exe
	-ssh $(DEPLOYMENT_HOST) -- 'taskkill /im amneziawg.exe /f'
	scp $< $(DEPLOYMENT_HOST):$(DEPLOYMENT_PATH)

clean:
	rm -rf *.syso ui/icon/*.ico x86/ amd64/ arm64/ .deps

distclean: clean
	rm -rf .distfiles

.PHONY: deploy clean distclean fmt remaster generate all
