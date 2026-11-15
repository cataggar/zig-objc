{
  description = "Objective-C runtime bindings for Zig";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";

    # Used for shell.nix
    flake-compat = {
      url = github:edolstra/flake-compat;
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  } @ inputs: let
    overlays = [
      # Other overlays
      (final: prev: {
        zigpkgs = inputs.zig.packages.${prev.system};
      })
    ];

    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
  in
    flake-utils.lib.eachSystem systems (
      system: let
        pkgs = import nixpkgs {inherit overlays system;};
        archive = {
          x86_64-linux = {target = "x86_64-linux"; sha256 = "3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a";};
          aarch64-linux = {target = "aarch64-linux"; sha256 = "a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795";};
          x86_64-darwin = {target = "x86_64-macos"; sha256 = "9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7";};
          aarch64-darwin = {target = "aarch64-macos"; sha256 = "75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d";};
        }.${system};
        zig017 = pkgs.stdenvNoCC.mkDerivation {
          pname = "zig";
          version = "0.17.1";
          src = pkgs.fetchurl {
            url = "https://github.com/cataggar/zig/releases/download/v0.17.1/zig-${archive.target}-0.17.1.tar.xz";
            inherit (archive) sha256;
          };
          dontConfigure = true;
          dontBuild = true;
          installPhase = ''
            mkdir -p "$out/bin" "$out/lib/zig"
            cp -r lib/. "$out/lib/zig/"
            cp zig "$out/bin/zig"
          '';
        };
      in rec {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            zig017
          ];
        };

        # For compatibility with older versions of the `nix` binary
        devShell = self.devShells.${system}.default;
      }
    );
}
