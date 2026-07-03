# Local ZMK Build Notes for Cornix

These are the commands that were verified to build this repository locally on macOS from the repository root.

> The README's older `-DZMK_EXTRA_MODULES=$PWD` flow can fail in this repo with a recursive `Kconfig.zephyr` error, because this repository also contains a top-level `zephyr/` checkout. Use `BOARD_ROOT`, `SHIELD_ROOT`, and `SNIPPET_ROOT` instead.

## Nix flake helper

This repository now provides flake apps for repeatable local builds. From the repo root:

```bash
# Initialize or update the west workspace/dependencies
nix run .#init

# Standard Nix build: fetch the west workspace, compile all default UF2s,
# and expose them under ./result/
nix build

# Working-tree helper: build left, right, and reset UF2s, then copy them into firmware/
nix run .#build

# Or build only one target with the working-tree helper
nix run .#build -- left
nix run .#build -- right
nix run .#build -- reset
```

`nix build` outputs are exposed at:

```text
result/cornix_left_default_nosd.uf2
result/cornix_right_nosd.uf2
result/cornix_reset.uf2
```

`nix run .#build` outputs are copied to:

```text
firmware/cornix_left_default_nosd.uf2
firmware/cornix_right_nosd.uf2
firmware/cornix_reset.uf2
```

## 1. Manual: initialize/update the west workspace

From the repo root:

```bash
cd /${<path>}/zmk-keyboard-cornix

# Only needed if .west is missing or broken
rm -rf .west
west init -l config

# Fetch/update ZMK and Zephyr dependencies
west update --fetch-opt=--filter=blob:none
west zephyr-export
```

If `west update` is interrupted and later complains about `index.lock`, remove the stale lock and rerun:

```bash
find . -path '*/.git/index.lock' -delete
west update --fetch-opt=--filter=blob:none
```

## 2. Build normal no-dongle firmware

### Left half

```bash
west build -s zmk/app -d build/cornix_left \
  -b cornix_left -- \
  -DZMK_CONFIG="$PWD/config" \
  -DBOARD_ROOT="$PWD" \
  -DSHIELD_ROOT="$PWD" \
  -DSNIPPET_ROOT="$PWD"
```

Output:

```text
build/cornix_left/zephyr/zmk.uf2
```

### Right half

```bash
west build -s zmk/app -d build/cornix_right \
  -b cornix_right -- \
  -DZMK_CONFIG="$PWD/config" \
  -DBOARD_ROOT="$PWD" \
  -DSHIELD_ROOT="$PWD" \
  -DSNIPPET_ROOT="$PWD"
```

Output:

```text
build/cornix_right/zephyr/zmk.uf2
```

## 3. Build reset firmware

```bash
west build -s zmk/app -d build/cornix_reset \
  -b cornix_right \
  -S studio-rpc-usb-uart \
  -S nrf52840-nosd -- \
  -DZMK_CONFIG="$PWD/config" \
  -DBOARD_ROOT="$PWD" \
  -DSHIELD_ROOT="$PWD" \
  -DSNIPPET_ROOT="$PWD" \
  -DSHIELD=settings_reset
```

Output:

```text
build/cornix_reset/zephyr/zmk.uf2
```

## 4. Optional: collect artifacts

```bash
mkdir -p firmware
cp build/cornix_left/zephyr/zmk.uf2 firmware/cornix_left_default_nosd.uf2
cp build/cornix_right/zephyr/zmk.uf2 firmware/cornix_right_nosd.uf2
cp build/cornix_reset/zephyr/zmk.uf2 firmware/cornix_reset.uf2
```

## 5. Flashing order

Recommended order:

1. Flash `firmware/cornix_reset.uf2` to both halves.
2. Flash `firmware/cornix_left_default_nosd.uf2` to the left half.
3. Flash `firmware/cornix_right_nosd.uf2` to the right half.
4. Reset both halves.

## Notes

- Use `cornix_left` and `cornix_right` for normal no-dongle builds.
- Use `cornix_ph_left` for the left half when building for a dongle setup.
- The `nrf52840-nosd` snippet is used by reset/dongle targets and is available from `zmk/app/snippets` after `west update`.
