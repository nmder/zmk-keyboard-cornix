{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # This pins requirements.txt provided by zephyr-nix.pythonEnv.
    zephyr.url = "github:zephyrproject-rtos/zephyr/v3.7.0";
    zephyr.flake = false;

    # Zephyr sdk and toolchain.
    zephyr-nix.url = "github:urob/zephyr-nix";
    zephyr-nix.inputs.zephyr.follows = "zephyr";
    zephyr-nix.inputs.nixpkgs.follows = "nixpkgs";

    keymap_drawer-nix = {
      url = "github:hitsmaxft/keymap-drawer";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zephyr-nix, keymap_drawer-nix, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zephyr = zephyr-nix.packages.${system};
          zephyrPyEnv = zephyr-nix.packages.${system}.pythonEnv;
          zephyrSdk = zephyr.sdk-0_16.override { targets = [ "arm-zephyr-eabi" ]; };
          pythonProtobuf = pkgs.python312Packages.protobuf;

          commonRuntimeInputs = with pkgs; [
            git
            coreutils
            findutils
            gnugrep
            gnused
            cmake
            dtc
            ninja
            protobuf
            zephyrPyEnv
            zephyrSdk
          ];
        in rec {
          cornix-init = pkgs.writeShellApplication {
            name = "cornix-init";
            runtimeInputs = commonRuntimeInputs;
            text = ''
              set -euo pipefail

              if [[ ! -f config/west.yml ]]; then
                echo "Run this from the zmk-keyboard-cornix repository root." >&2
                exit 1
              fi

              export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
              export ZEPHYR_SDK_INSTALL_DIR=${zephyrSdk}

              if [[ ! -d .west ]]; then
                west init -l config
              fi

              find . -path '*/.git/index.lock' -delete 2>/dev/null || true
              west update --fetch-opt=--filter=blob:none
              west zephyr-export
            '';
          };

          cornix-build = pkgs.writeShellApplication {
            name = "cornix-build";
            runtimeInputs = commonRuntimeInputs;
            text = ''
              set -euo pipefail

              if [[ ! -f config/west.yml ]]; then
                echo "Run this from the zmk-keyboard-cornix repository root." >&2
                exit 1
              fi

              if [[ ! -d .west || ! -d zmk/app || ! -d zephyr ]]; then
                echo "West workspace is not initialized. Run: nix run .#init" >&2
                exit 1
              fi

              export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
              export ZEPHYR_SDK_INSTALL_DIR=${zephyrSdk}
              export PYTHONPATH="${pythonProtobuf}/${pkgs.python312.sitePackages}:''${PYTHONPATH:-}"

              target="''${1:-all}"

              build_left() {
                west build -p always -s zmk/app -d build/cornix_left \
                  -b cornix_left -- \
                  -DZMK_CONFIG="$PWD/config" \
                  -DBOARD_ROOT="$PWD" \
                  -DSHIELD_ROOT="$PWD" \
                  -DSNIPPET_ROOT="$PWD" \
                  -DSHIELD=cornix_indicator
              }

              build_right() {
                west build -p always -s zmk/app -d build/cornix_right \
                  -b cornix_right -- \
                  -DZMK_CONFIG="$PWD/config" \
                  -DBOARD_ROOT="$PWD" \
                  -DSHIELD_ROOT="$PWD" \
                  -DSNIPPET_ROOT="$PWD" \
                  -DSHIELD=cornix_indicator
              }

              build_reset() {
                west build -p always -s zmk/app -d build/cornix_reset \
                  -b cornix_right \
                  -S studio-rpc-usb-uart \
                  -S nrf52840-nosd -- \
                  -DZMK_CONFIG="$PWD/config" \
                  -DBOARD_ROOT="$PWD" \
                  -DSHIELD_ROOT="$PWD" \
                  -DSNIPPET_ROOT="$PWD" \
                  -DSHIELD=settings_reset
              }

              collect_artifacts() {
                mkdir -p firmware
                [[ -f build/cornix_left/zephyr/zmk.uf2 ]] && \
                  cp build/cornix_left/zephyr/zmk.uf2 firmware/cornix_left_default_nosd.uf2
                [[ -f build/cornix_right/zephyr/zmk.uf2 ]] && \
                  cp build/cornix_right/zephyr/zmk.uf2 firmware/cornix_right_nosd.uf2
                [[ -f build/cornix_reset/zephyr/zmk.uf2 ]] && \
                  cp build/cornix_reset/zephyr/zmk.uf2 firmware/cornix_reset.uf2
                ls -lh firmware/*.uf2 2>/dev/null || true
              }

              case "$target" in
                left)
                  build_left
                  collect_artifacts
                  ;;
                right)
                  build_right
                  collect_artifacts
                  ;;
                reset)
                  build_reset
                  collect_artifacts
                  ;;
                all|default|no-dongle|led)
                  build_left
                  build_right
                  build_reset
                  collect_artifacts
                  ;;
                *)
                  echo "Usage: cornix-build [all|led|left|right|reset]" >&2
                  exit 2
                  ;;
              esac
            '';
          };

          cornix-firmware = pkgs.stdenvNoCC.mkDerivation {
            pname = "cornix-firmware";
            version = "unstable";
            src = self;

            nativeBuildInputs = commonRuntimeInputs;

            # This package intentionally performs the same west workspace fetches
            # as the GitHub Actions build. The manifest currently tracks moving
            # branches, so this is a local-build convenience rather than a fully
            # fixed-output/reproducible Nix package.
            __noChroot = true;

            dontConfigure = true;
            dontFixup = true;

            buildPhase = ''
              runHook preBuild

              export HOME="$TMPDIR/home"
              export XDG_CACHE_HOME="$TMPDIR/cache"
              mkdir -p "$HOME" "$XDG_CACHE_HOME"

              export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
              export ZEPHYR_SDK_INSTALL_DIR=${zephyrSdk}
              export PYTHONPATH="${pythonProtobuf}/${pkgs.python312.sitePackages}:''${PYTHONPATH:-}"
              export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
              export GIT_SSL_CAINFO="$SSL_CERT_FILE"

              west init -l config
              west update --fetch-opt=--filter=blob:none
              west zephyr-export

              west build -p always -s zmk/app -d build/cornix_left \
                -b cornix_left -- \
                -DZMK_CONFIG="$PWD/config" \
                -DBOARD_ROOT="$PWD" \
                -DSHIELD_ROOT="$PWD" \
                -DSNIPPET_ROOT="$PWD" \
                -DSHIELD=cornix_indicator

              west build -p always -s zmk/app -d build/cornix_right \
                -b cornix_right -- \
                -DZMK_CONFIG="$PWD/config" \
                -DBOARD_ROOT="$PWD" \
                -DSHIELD_ROOT="$PWD" \
                -DSNIPPET_ROOT="$PWD" \
                -DSHIELD=cornix_indicator

              west build -p always -s zmk/app -d build/cornix_reset \
                -b cornix_right \
                -S studio-rpc-usb-uart \
                -S nrf52840-nosd -- \
                -DZMK_CONFIG="$PWD/config" \
                -DBOARD_ROOT="$PWD" \
                -DSHIELD_ROOT="$PWD" \
                -DSNIPPET_ROOT="$PWD" \
                -DSHIELD=settings_reset

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p "$out"
              cp build/cornix_left/zephyr/zmk.uf2 "$out/cornix_left_default_nosd.uf2"
              cp build/cornix_right/zephyr/zmk.uf2 "$out/cornix_right_nosd.uf2"
              cp build/cornix_reset/zephyr/zmk.uf2 "$out/cornix_reset.uf2"

              runHook postInstall
            '';
          };

          cornix-clean = pkgs.writeShellApplication {
            name = "cornix-clean";
            runtimeInputs = with pkgs; [ coreutils findutils ];
            text = ''
              set -euo pipefail

              if [[ ! -f config/west.yml ]]; then
                echo "Run this from the zmk-keyboard-cornix repository root." >&2
                exit 1
              fi

              target="''${1:-build}"

              case "$target" in
                build)
                  rm -rf build firmware
                  ;;
                rgbled|zmk-rgbled-widget)
                  rm -rf zmk-rgbled-widget
                  ;;
                deps|west-deps)
                  rm -rf zmk zmk-helpers zmk-rgbled-widget zmk-dongle-display modules optional
                  find . -path '*/.git/index.lock' -delete 2>/dev/null || true
                  ;;
                all)
                  rm -rf build firmware zmk zmk-helpers zmk-rgbled-widget zmk-dongle-display modules optional
                  find . -path '*/.git/index.lock' -delete 2>/dev/null || true
                  ;;
                *)
                  echo "Usage: cornix-clean [build|rgbled|deps|all]" >&2
                  exit 2
                  ;;
              esac
            '';
          };

          default = cornix-firmware;
        });

      apps = forAllSystems (system: {
        init = {
          type = "app";
          program = "${self.packages.${system}.cornix-init}/bin/cornix-init";
        };
        build = {
          type = "app";
          program = "${self.packages.${system}.cornix-build}/bin/cornix-build";
        };
        clean = {
          type = "app";
          program = "${self.packages.${system}.cornix-clean}/bin/cornix-clean";
        };
        default = {
          type = "app";
          program = "${self.packages.${system}.cornix-build}/bin/cornix-build";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zephyr = zephyr-nix.packages.${system};
          zephyrPyEnv = zephyr-nix.packages.${system}.pythonEnv;
          zephyrSdk = zephyr.sdk-0_16.override { targets = [ "arm-zephyr-eabi" ]; };
          keymap_drawer = keymap_drawer-nix.packages.${system}.default;
        in {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              gcovr
              gcc-arm-embedded
              zephyrPyEnv
              zephyrSdk
              cmake
              dtc
              ninja
              just
              yq # Make sure yq resolves to python-yq.
              tio
              keymap_drawer
            ];

            # Never export ZEPHYR_BASE; west owns it. Zephyr_DIR is useful for CMake tooling.
            shellHook = ''
              export ZMK_LIB_PREFIX="''${ZMK_LIB_PREFIX:=zmk_exts}"
              export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
              export ZEPHYR_SDK_INSTALL_DIR=${zephyrSdk}

              if west config zephyr.base >/dev/null 2>&1; then
                Zephyr_DIR="$(west config zephyr.base)/share/zephyr-package/cmake/"
                export Zephyr_DIR
              fi

              echo "use lib prefix $ZMK_LIB_PREFIX"
            '';
          };
        });
    };
}
