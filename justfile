# Default commands
test *args: (test-forge args)
build *args: (build-forge args)
prep *args: fix (test-forge args)

# Forge commands
test-forge *args: build-forge
    forge test --isolate {{args}}

build-forge *args: install-forge
    forge build {{args}}

install-forge:
    forge install

# Formatting
fix:
    forge fmt
