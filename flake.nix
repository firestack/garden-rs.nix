{
	description = "Nix build of https://gitlab.com/garden-rs/garden";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

		crane = {
			url = "github:ipetkov/crane";
			inputs.nixpkgs.follows = "nixpkgs";
		};

		fenix = {
			url = "github:nix-community/fenix";
			inputs.nixpkgs.follows = "nixpkgs";
			inputs.rust-analyzer-src.follows = "";
		};

		flake-utils.url = "github:numtide/flake-utils";

		advisory-db = {
			url = "github:rustsec/advisory-db";
			flake = false;
		};

		garden-rs-src = {
			url = "gitlab:garden-rs/garden";
			flake = false;
		};
	};

	outputs = { self, nixpkgs, crane, fenix, flake-utils, advisory-db, garden-rs-src, ... }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = import nixpkgs {
					inherit system;
				};

				inherit (pkgs) lib;

				craneLib = crane.lib.${system};
				src = garden-rs-src;

				# Common arguments can be set here to avoid repeating them later
				commonArgs = {
					inherit src;

					buildInputs = [
						# Add additional build inputs here
					] ++ lib.optionals pkgs.stdenv.isDarwin [
						# Additional darwin specific inputs can be set here
						pkgs.libiconv
					];

					# Additional environment variables can be set directly
					# MY_CUSTOM_VAR = "some value";
				};

				craneLibLLvmTools = craneLib.overrideToolchain
					(fenix.packages.${system}.complete.withComponents [
						"cargo"
						"llvm-tools"
						"rustc"
					]);

				# Build *just* the cargo dependencies, so we can reuse
				# all of that work (e.g. via cachix) when running in CI
				cargoArtifacts = craneLib.buildDepsOnly commonArgs;

				# Build the actual crate itself, reusing the dependency
				# artifacts from above.
				garden-rs = craneLib.buildPackage (commonArgs // {
					inherit cargoArtifacts;

					nativeCheckInputs = [
						pkgs.git
					];
				});
			in
			{
				checks = {
					# Build the crate as part of `nix flake check` for convenience
					inherit garden-rs;

					# Run clippy (and deny all warnings) on the crate source,
					# again, resuing the dependency artifacts from above.
					#
					# Note that this is done as a separate derivation so that
					# we can block the CI if there are issues here, but not
					# prevent downstream consumers from building our crate by itself.
					garden-rs-clippy = craneLib.cargoClippy (commonArgs // {
						inherit cargoArtifacts;
						cargoClippyExtraArgs = "--all-targets -- --deny warnings";
					});

					garden-rs-doc = craneLib.cargoDoc (commonArgs // {
						inherit cargoArtifacts;
					});

					# Check formatting
					garden-rs-fmt = craneLib.cargoFmt {
						inherit src;
					};

					# Audit dependencies
					garden-rs-audit = craneLib.cargoAudit {
						inherit src advisory-db;
					};

					# Run tests with cargo-nextest
					# Consider setting `doCheck = false` on `garden-rs` if you do not want
					# the tests to run twice
					garden-rs-nextest = craneLib.cargoNextest (commonArgs // {
						inherit cargoArtifacts;
						partitions = 1;
						partitionType = "count";
					});
				} // lib.optionalAttrs (system == "x86_64-linux") {
					# NB: cargo-tarpaulin only supports x86_64 systems
					# Check code coverage (note: this will not upload coverage anywhere)
					garden-rs-coverage = craneLib.cargoTarpaulin (commonArgs // {
						inherit cargoArtifacts;
					});
				};

				packages = {
					default = garden-rs;
					garden-rs-llvm-coverage = craneLibLLvmTools.cargoLlvmCov (commonArgs // {
						inherit cargoArtifacts;
					});
				};

				apps.default = flake-utils.lib.mkApp {
					drv = garden-rs;
				};

				devShells.default = pkgs.mkShell {
					inputsFrom = builtins.attrValues self.checks.${system};

					# Additional dev-shell environment variables can be set directly
					# MY_CUSTOM_DEVELOPMENT_VAR = "something else";

					# Extra inputs can be added here
					nativeBuildInputs = with pkgs; [
						cargo
						rustc
					];
				};
			});
}
