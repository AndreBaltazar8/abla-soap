ABLAC_DIR ?= $(abspath ../ablac)
COMPILER ?= ablac
TESTS := tests/envelope_test.ab tests/client_test.ab tests/wsdl_test.ab tests/generated_test.ab
# OpenSSL for what links it. On CI it's installed, and this is empty.
WITH_OPENSSL ?= nix-shell $(ABLAC_DIR)/shell.nix --run

.PHONY: all test generate tool subpaths at clean

all: test at

# No OpenSSL needed: nothing here imports the tls subpath. No float in the library either: nothing goes through one.
test: generate
	! grep -rnE '\b(f32|f64)\b|abla/float' src
	! grep -rnE 'import "abla/(http/tls|tls|crypto/hosted)' src --include='*.ab' --exclude=tls.ab
	$(COMPILER) test $(TESTS)

tool:
	mkdir -p build/gen
	$(COMPILER) package update --project . >/dev/null
	$(COMPILER) build tools/wsdl2abla.ab -o build/wsdl2abla

# The clients the tests use; the hostile one only has to compile.
generate: tool
	build/wsdl2abla tests/fixtures/shop.wsdl --prefix Shop --import '"../../src/soap.ab"' -o build/gen/shop.ab
	build/wsdl2abla tests/fixtures/hostile-names.wsdl --import '"../../src/soap.ab"' -o build/gen/hostile.ab
	printf 'import "hostile.ab"\nfun main: int = 0\n' > build/gen/check_hostile.ab
	$(COMPILER) build build/gen/check_hostile.ab -o build/gen/check_hostile

# AT's published WSDLs and a local mutual-TLS server, which doesn't call AT, and the subpaths, one of which links OpenSSL.
at: tool
ifeq ($(strip $(WITH_OPENSSL)),)
	tests/at/run.sh $(COMPILER)
	tests/subpaths.sh $(COMPILER)
else
	$(WITH_OPENSSL) 'tests/at/run.sh $(COMPILER) && tests/subpaths.sh $(COMPILER)'
endif

clean:
	@if [ -d build ]; then gio trash build; fi
