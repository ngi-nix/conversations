{
  description = "Androsphinx - a SPHINX app for Android.";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-21.05";
    gradle2nix.url = "github:tadfisher/gradle2nix";
    conversations-src = { url = "github:inputmice/conversations"; flake = false; };
  };

  outputs = { self, nixpkgs, gradle2nix, conversations-src }:
    let
      # System types to support.
      supportedSystems = [ "x86_64-linux" ];

      # Mapping from Nix' "system" to Android's "system".
      androidSystemByNixSystem = {
        "x86_64-linux" = "linux-x86_64";
        "x86_64-darwin" = "darwin-x86_64";
      };

      # Helper function to generate an attrset '{ x86_64-linux = f "x86_64-linux"; ... }'.
      forAllSystems = f:
        nixpkgs.lib.genAttrs supportedSystems (system: f system);
      
      lib = nixpkgs.lib;

      android = {
        versions = {
          tools = "26.1.1";
          platformTools = "31.0.2";
          buildTools = "30.0.2";
          ndk = [ "22.1.7171670" "21.3.6528147" ];
          cmake = "3.18.1";
          emulator = "30.6.3";
        };

        platforms = [ "28" "29" "30" ];
        abis = [ "armeabi-v7a" "arm64-v8a" ];
        extras = [ "extras;google;gcm" ];
      };


      # Nixpkgs instantiated for supported system types.
      nixpkgsFor = forAllSystems (system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlay ];
          config.android_sdk.accept_license = true;
        });
    in
    {

      # A Nixpkgs overlay.
      overlay = final: prev:
        with final.pkgs; {
          sdk = (pkgs.androidenv.composeAndroidPackages {
            toolsVersion = android.versions.tools;
            platformToolsVersion = android.versions.platformTools;
            buildToolsVersions = [ android.versions.buildTools ];
            platformVersions = android.platforms;

            includeEmulator = false;
            includeSources = false;
            includeSystemImages = false;

            systemImageTypes = [ "google_apis_playstore" ];
            abiVersions = android.abis;
            cmakeVersions = [ android.versions.cmake ];

            includeNDK = false;
            useGoogleAPIs = false;
            useGoogleTVAddOns = false;
            includeExtras = android.extras;
          });

          conversations = (pkgs.callPackage ./gradle-env.nix {}) rec {
            envSpec = ./gradle-env.json;
    
            src = conversations-src;

            buildJdk = pkgs.jdk11;
            ANDROID_SDK_ROOT = "${pkgs.sdk.androidsdk}/libexec/android-sdk";
    
            preBuild = ''
              # Make gradle aware of Android SDK.
              # See https://github.com/tadfisher/gradle2nix/issues/13
              echo "sdk.dir = ${sdk.androidsdk}/libexec/android-sdk" > local.properties
              printf "\nandroid.aapt2FromMavenOverride=${sdk.androidsdk}/libexec/android-sdk/build-tools/${android.versions.buildTools}/aapt2" >> gradle.properties
            '';

            gradleFlags = [
              "assembleConversationsFreeSystemDebug"
            ];

            installPhase = ''
              mkdir -p $out
              find . -name '*.apk' -exec cp {} $out \;
            '';

            nativeBuildInputs = [
              pkgs.breakpointHook
            ];
          };
        };

      # Provide a nix-shell env to work with.
      devShell = forAllSystems (system:
        with nixpkgsFor.${system};
        mkShell rec {
          buildInputs = [
            sdk.androidsdk
            adoptopenjdk-jre-openj9-bin-15
            gradle
            gradle2nix.outputs.defaultPackage."${system}"
          ];
          ANDROID_SDK_ROOT = "${sdk.androidsdk}/libexec/android-sdk";
          JAVA_HOME = "${adoptopenjdk-jre-openj9-bin-15.home}";
          GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${ANDROID_SDK_ROOT}/build-tools/${android.versions.buildTools}/aapt2";
          # DEBUG_APK = "${conversations}/app-debug.apk";
          src = conversations-src;
        });

      # Provide some binary packages for selected system types.
      packages = forAllSystems (system: {
        inherit (nixpkgsFor.${system}) conversations;
      });

      apps = forAllSystems (system: 
        let
          pkgs = nixpkgsFor."${system}";
        in
        {
          run-gradle2nix = {
            type = "app";
            program = builtins.toString (pkgs.writeScript "run-gradle2nix" ''
              PATH=${lib.makeBinPath (with pkgs; [
                coreutils
                gnused
                gradle2nix.outputs.defaultPackage."${system}"
              ])}
              export JAVA_HOME=${pkgs.jdk11.home};
              export ANDROID_SDK_ROOT="${pkgs.sdk.androidsdk}/libexec/android-sdk"
              set -e
              rm -rf src
              cp -r ${conversations-src} src
              chmod -R +w src
              
              gradle2nix \
                -o . \
                -c assembleConversationsFreeSystemDebug \
                src
              rm -rf src
            '');
          };
        }
      );

      defaultPackage =
        forAllSystems (system: self.packages.${system}.conversations);

    };
}
