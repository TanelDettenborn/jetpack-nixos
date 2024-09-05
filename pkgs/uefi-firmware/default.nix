{ lib
, stdenv
, buildPackages
, fetchFromGitHub
, fetchurl
, fetchpatch
, fetchpatch2
, runCommand
, edk2
, acpica-tools
, dtc
, python3
, bc
, imagemagick
, unixtools
, libuuid
, applyPatches
, nukeReferences
, l4tVersion
, # Optional path to a boot logo that will be converted and cropped into the format required
  bootLogo ? null
, # Patches to apply to edk2-nvidia source tree
  edk2NvidiaPatches ? [ ]
, # Patches to apply to edk2 source tree
  edk2UefiPatches ? [ ]
, debugMode ? false
, errorLevelInfo ? debugMode
, # Enables a bunch more info messages

  # The root certificate (in PEM format) for authenticating capsule updates. By
  # default, EDK2 authenticates using a test keypair commited upstream.
  trustedPublicCertPemFile ? null
,
}:

let

  l4tVersion = "36.3.0";

  edk2-src = fetchFromGitHub {
    name = "edk2-src";
    owner = "NVIDIA";
    repo = "edk2";
    rev = "r${l4tVersion}";
    fetchSubmodules = true;
    sha256 = "sha256-FmQHcCbSXdeNS1/u5xlhazhP75nRyNuCK1D5AREQsIA=";
  };

  edk2-platforms = fetchFromGitHub {
    name = "edk2-platforms";
    owner = "NVIDIA";
    repo = "edk2-platforms";
    rev = "r${l4tVersion}";
    fetchSubmodules = true;
    sha256 = "sha256-Z89AkLvoG7pSOHUlU7IWLREM3R79kABpHj7KS5XpX0o=";
  };

  edk2-non-osi = fetchFromGitHub {
    name = "edk2-non-osi";
    owner = "NVIDIA";
    repo = "edk2-non-osi";
    rev = "r${l4tVersion}";
    sha256 = "sha256-FnznH8KsB3rD7sL5Lx2GuQZRPZ+uqAYqenjk+7x89mE=";
  };

  edk2-nvidia = fetchFromGitHub {
    name = "edk2-nvidia";
    owner = "NVIDIA";
    repo = "edk2-nvidia";
    rev = "r${l4tVersion}";
    sha256 = "sha256-LaSko7jCgrM3nbDnzF4yCoSXFnFq4OeHTCeprf4VgjI=";
  };

  edk2-nvidia-non-osi = fetchFromGitHub {
    name = "edk2-nvidia-non-osi";
    owner = "NVIDIA";
    repo = "edk2-nvidia-non-osi";
    rev = "r${l4tVersion}";
    sha256 = "sha256-aoOTjoL33s57lBd6VfKXmlJnTg26+vD8JNToYBTaJ6w=";
  };

  edk2-open-gpu-kernel-modules = fetchFromGitHub {
    name = "edk2-open-gpu-kernel-modules";
    owner = "NVIDIA";
    repo = "open-gpu-kernel-modules";
    rev = "dac2350c7f6496ef0d7fb20fe6123a1270329bc8"; # 525.78.01
    sha256 = "sha256-fxpyXVl735ZJ3NnK7jN95gPstu7YopYH/K7UK0iAC7k=";
  };

  pythonEnv = buildPackages.python3.withPackages (ps: [
    ps.edk2-pytool-library
    (ps.callPackage ./edk2-pytool-extensions.nix { })
    ps.tkinter
    ps.regex
    ps.kconfiglib
  ]);

  targetArch =
    if stdenv.isi686 then
      "IA32"
    else if stdenv.isx86_64 then
      "X64"
    else if stdenv.isAarch64 then
      "AARCH64"
    else
      throw "Unsupported architecture";

  buildType =
    if stdenv.isDarwin then
      "CLANGPDB"
    else
      "GCC5";

  jetson-edk2-uefi =

    stdenv.mkDerivation {
      pname = "jetson-edk2-uefi";
      version = l4tVersion;

      srcs = [
        edk2-open-gpu-kernel-modules
        edk2-nvidia-non-osi
        edk2-nvidia
        edk2-non-osi
        edk2-platforms
        edk2-src
      ];
      sourceRoot = edk2-src.name;

      depsHostHost = [
        libuuid
      ];
      depsBuildBuild = [
        buildPackages.stdenv.cc
        buildPackages.bash
      ];
      nativeBuildInputs = [
        pythonEnv
        buildPackages.libuuid
        buildPackages.dtc
        buildPackages.acpica-tools
        buildPackages.gnat
        buildPackages.bash
        # useful for debugging
        #buildPackages.strace
      ];

      strictDeps = true;

      buildPhase = ''
        runHook preBuild

        cd ..
        mkdir edk2-nvidia-server-gpu-sdk
        ln -s open-gpu-kernel-modules edk2-nvidia-server-gpu-sdk/open-gpu-kernel-modules

        export WORKSPACE="$PWD"
        export PYTHONPATH="$PWD"/edk2-nvidia/Silicon/NVIDIA/scripts/..

        rm -rf bin && mkdir bin && chmod +x bin

        # nvidia expects gcc-ar and ar to be in the same directory as gcc
        for tool in gcc cc g++ c++ gcc-ar ar cpp objcopy; do
          ln -s $(command -v ${stdenv.cc.targetPrefix}$tool) bin/${stdenv.cc.targetPrefix}$tool
        done
        export CROSS_COMPILER_PREFIX="$PWD"/bin/${stdenv.cc.targetPrefix}
        ''${CROSS_COMPILER_PREFIX}gcc --version
        export ${"GCC5_${targetArch}_PREFIX"}=$CROSS_COMPILER_PREFIX

        chmod -R +w edk2-nvidia edk2-src
        mv edk2-src edk2

        # patchShebangs fails to see these when cross compiling
        for i in edk2/BaseTools/BinWrappers/PosixLike/*; do
          chmod +x "$i"
          patchShebangs --build "$i"
        done

        # delete this so it doesn't trigger a nuget download
        rm ./edk2/BaseTools/Bin/nasm_ext_dep.yaml ./edk2-nvidia/Platform/NVIDIA/iasl_ext_dep.yaml
        stuart_update -c "$PWD"/edk2-nvidia/Platform/NVIDIA/Jetson/PlatformBuild.py
        python edk2/BaseTools/Edk2ToolsBuild.py -t GCC

        # FIXME/NIXIFY: Use iasl-tool from pkgs
        mkdir -p edk2-nvidia/Platform/NVIDIA/edk2-acpica-iasl_extdep/Linux-x86
        rm -f edk2-nvidia/Platform/NVIDIA/edk2-acpica-iasl_extdep/Linux-x86/iasl
        ln -s $(command -v iasl) edk2-nvidia/Platform/NVIDIA/edk2-acpica-iasl_extdep/Linux-x86/iasl

        ## useful for debugging
        ## ps aux | grep sleep
        ## sudo nsenter --target 481604 --mount --uts --net --pid --cgroup $(nix build --print-out-paths --inputs-from . nixpkgs#bash.out)/bin/bash
        #stuart_build -c "$PWD"/edk2-nvidia/Platform/NVIDIA/Jetson/PlatformBuild.py || {
        #  echo "Build failed"
        #  sleep 9999999
        #  exit 1
        #}

        stuart_build -c "$PWD"/edk2-nvidia/Platform/NVIDIA/Jetson/PlatformBuild.py
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mv -v Build/*/* $out
        runHook postInstall
      '';
    };

  uefi-firmware = runCommand "uefi-firmware-${l4tVersion}"
    {
      nativeBuildInputs = [ python3 nukeReferences ];
    } ''
    mkdir -p $out
    python3 ${edk2-nvidia}/Silicon/NVIDIA/Tools/FormatUefiBinary.py \
      ${jetson-edk2-uefi}/FV/UEFI_NS.Fv \
      $out/uefi_jetson.bin

    python3 ${edk2-nvidia}/Silicon/NVIDIA/Tools/FormatUefiBinary.py \
      ${jetson-edk2-uefi}/AARCH64/L4TLauncher.efi \
      $out/L4TLauncher.efi

    mkdir -p $out/dtbs
    for filename in ${jetson-edk2-uefi}/AARCH64/Silicon/NVIDIA/Tegra/DeviceTree/DeviceTree/OUTPUT/*.dtb; do
      cp $filename $out/dtbs/$(basename "$filename" ".dtb").dtbo
    done

    # Get rid of any string references to source(s)
    nuke-refs $out/uefi_jetson.bin
  '';
in
{
  inherit edk2-src uefi-firmware;
}
