{
  description = "litem8 - SQLite migration tool";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs = inputs @ { flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem = { self', system, lib, ... }:
        let
          env = inputs.zig2nix.outputs.zig-env.${system} {
            zig = inputs.zig2nix.outputs.packages.${system}.zig-latest;
          };
          pkgs = env.pkgs;
        in
        {
          packages = {
            litem8 = env.package {
              src = lib.cleanSource ./.;
              nativeBuildInputs = [ ];
              buildInputs = [ ];

              # Copy the zig-built libsqlite.so to output and fix RPATH before the check runs
              preFixup = ''
                # Find libsqlite.so in the build cache
                SQLITE_SRC=$(find /build -name "libsqlite.so" -type f 2>/dev/null | head -1 || true)
                if [ -n "$SQLITE_SRC" ]; then
                  mkdir -p $out/lib
                  cp "$SQLITE_SRC" $out/lib/
                  ${pkgs.patchelf}/bin/patchelf --set-rpath "$out/lib" $out/bin/litem8
                fi
              '';

              meta = {
                description = "SQLite migration tool";
                mainProgram = "litem8";
              };
            };

            # Static musl builds for minimal container images
            litem8-static-x86_64 = env.package {
              src = lib.cleanSource ./.;
              nativeBuildInputs = [ ];
              buildInputs = [ ];
              zigBuildFlags = [ "-Dtarget=x86_64-linux-musl" ];
              meta = {
                description = "SQLite migration tool (static x86_64 build)";
                mainProgram = "litem8";
              };
            };

            litem8-static-aarch64 = env.package {
              src = lib.cleanSource ./.;
              nativeBuildInputs = [ ];
              buildInputs = [ ];
              zigBuildFlags = [ "-Dtarget=aarch64-linux-musl" ];
              meta = {
                description = "SQLite migration tool (static aarch64 build)";
                mainProgram = "litem8";
              };
            };

            default = self'.packages.litem8;
          };

          apps = {
            litem8 = {
              type = "app";
              program = lib.getExe self'.packages.litem8;
            };
            default = self'.apps.litem8;
          };

          devShells.default = env.mkShell {
            nativeBuildInputs = [
              pkgs.sqlite
            ];
          };
        };
    };
}
