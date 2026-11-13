#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Write OpenVRLink.xcodeproj for the visionOS app.

The app is the Swift files in Sources/ plus the libraries of the Swift package
one directory up. Run this after adding or removing a source file, then:

    xcodebuild -project OpenVRLink.xcodeproj -scheme OpenVRLink \\
        -destination 'generic/platform=visionOS' -allowProvisioningUpdates build

OPENVRLINK_TEAM and OPENVRLINK_BUNDLE_ID override the signing team (default:
the one on this Mac's Apple Development certificate) and the bundle id
(default: one made from the signing team, see bundle_identifier).
"""
import shutil
import getpass
import hashlib
import os
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
NAME = "OpenVRLink"
PACKAGE_PRODUCTS = ["VRLinkCore", "VRLinkApple", "VRLinkExperiments"]
# queryDrawables and the rest of the current drawable API need visionOS 26.
DEPLOYMENT_TARGET = "26.0"
# The project's own bundle id, and the only one Apple has granted the
# low-latency streaming entitlement (OpenVRLink.entitlements). Signing any
# other id with that entitlement fails, so other ids are signed without it.
OWN_BUNDLE_ID = "dev.maxthomas.rel.OpenVRLink"
MARKETING_VERSION = "0.1.0"
BUILD_NUMBER = "5"


def object_id(tag):
    return hashlib.sha1(tag.encode()).hexdigest()[:24].upper()


def quoted(value):
    return value if re.fullmatch(r"[A-Za-z0-9_./-]+", value) else '"%s"' % value.replace('"', '\\"')


def signing_team():
    """The team id on the first Apple Development certificate, or empty."""
    if os.environ.get("OPENVRLINK_TEAM"):
        return os.environ["OPENVRLINK_TEAM"]
    try:
        identities = subprocess.run(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
                                    capture_output=True, text=True).stdout
        first = identities.split("-----END CERTIFICATE-----")[0] + "-----END CERTIFICATE-----\n"
        subject = subprocess.run(["openssl", "x509", "-noout", "-subject"], input=first,
                                 capture_output=True, text=True).stdout
        match = re.search(r"OU\s*=\s*([A-Z0-9]{10})", subject)
        return match.group(1) if match else ""
    except OSError:
        return ""


def bundle_identifier(team):
    """The app's bundle id. A bundle id belongs to the first team that signs
    with it, so only the project's owner builds with the project's own; anyone
    else gets one made from their team id (or their user name, with no team),
    which is theirs alone and the same on every build."""
    if os.environ.get("OPENVRLINK_BUNDLE_ID"):
        return os.environ["OPENVRLINK_BUNDLE_ID"]
    if getpass.getuser() == "maxamillion":
        return OWN_BUNDLE_ID
    own = re.sub(r"[^a-z0-9-]", "-", (team or getpass.getuser()).lower())
    return f"dev.openvrlink.{own}.OpenVRLink"


def main():
    sources = sorted(path.name for path in (HERE / "Sources").glob("*.swift"))
    # Files copied into the app as they are (RealityKit material definitions).
    (HERE / "Resources").mkdir(exist_ok=True)
    # The app icon's layers, so the entry window can draw the icon: an app
    # cannot load its own icon from the asset catalog.
    for layer in ("Back", "Middle", "Front"):
        shutil.copyfile(HERE / f"Assets.xcassets/AppIcon.solidimagestack/{layer}.solidimagestacklayer"
                        f"/Content.imageset/{layer}.png", HERE / f"Resources/Icon{layer}.png")
    resources = sorted(path.name for path in (HERE / "Resources").glob("*") if path.is_file())
    team = signing_team()
    bundle_id = bundle_identifier(team)
    if not team:
        print("no Apple Development certificate found: set OPENVRLINK_TEAM to your team id, "
              "or sign in to Xcode (Settings > Accounts) and build once there")

    project, target, product = object_id("project"), object_id("target"), object_id("product")
    main_group, source_group, products_group = object_id("group"), object_id("sources-group"), object_id("products")
    sources_phase, frameworks_phase = object_id("sources-phase"), object_id("frameworks-phase")
    resources_phase, resource_group = object_id("resources-phase"), object_id("resources-group")
    resource_refs = "".join(
        f"\t\t{object_id('resref' + name)} = {{isa = PBXFileReference; lastKnownFileType = text; "
        f"path = {quoted(name)}; sourceTree = \"<group>\"; }};\n" for name in resources)
    resource_build_files = "".join(
        f"\t\t{object_id('resbuild' + name)} = {{isa = PBXBuildFile; fileRef = {object_id('resref' + name)}; }};\n"
        for name in resources)
    package = object_id("package")
    plist = object_id("plist")
    # The asset catalog holds the app icon (three layers; design/icon-drafts/export_visionos.py writes them).
    assets, assets_build = object_id("assets"), object_id("assets-build")

    file_refs = "".join(
        f"\t\t{object_id('ref' + name)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
        f"path = {quoted(name)}; sourceTree = \"<group>\"; }};\n" for name in sources)
    build_files = "".join(
        f"\t\t{object_id('build' + name)} = {{isa = PBXBuildFile; fileRef = {object_id('ref' + name)}; }};\n"
        for name in sources)
    product_build_files = "".join(
        f"\t\t{object_id('pbuild' + name)} = {{isa = PBXBuildFile; productRef = {object_id('dep' + name)}; }};\n"
        for name in PACKAGE_PRODUCTS)
    dependencies = "".join(
        f"\t\t{object_id('dep' + name)} = {{isa = XCSwiftPackageProductDependency; productName = {name}; }};\n"
        for name in PACKAGE_PRODUCTS)

    def configuration(tag, name, settings):
        body = "".join(f"\t\t\t\t{key} = {quoted(value)};\n" for key, value in sorted(settings.items()))
        return (f"\t\t{object_id(tag)} = {{isa = XCBuildConfiguration; buildSettings = {{\n{body}\t\t\t}}; "
                f"name = {name}; }};\n")

    target_settings = {
        "PRODUCT_NAME": NAME, "PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
        "INFOPLIST_FILE": "Info.plist", "GENERATE_INFOPLIST_FILE": "YES",
        "SDKROOT": "xros", "SUPPORTED_PLATFORMS": "xros xrsimulator", "TARGETED_DEVICE_FAMILY": "7",
        "XROS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET, "SWIFT_VERSION": "5.0",
        "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": team,
        "MARKETING_VERSION": MARKETING_VERSION, "CURRENT_PROJECT_VERSION": BUILD_NUMBER,
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        # Info.plist entries that have a build setting live here and not in
        # Info.plist: Xcode moves any it finds there into the project when it
        # opens it, and this project file is generated, so they would be lost.
        # Info.plist keeps only what has no build setting (the scene manifest,
        # without whose immersive-space entry the space opens and every frame
        # is presented into nothing; and the list of game controllers).
        # Without the local network entry, traffic to the Steam host is silently discarded.
        "INFOPLIST_KEY_NSLocalNetworkUsageDescription":
            "OpenVRLink connects to Steam on a computer on your local network.",
        "INFOPLIST_KEY_NSMicrophoneUsageDescription":
            "OpenVRLink sends your voice to SteamVR when you turn the microphone on.",
        "INFOPLIST_KEY_NSCameraUsageDescription":
            "OpenVRLink reads your expressions off your Spatial Persona to send face tracking to SteamVR, "
            "when you turn that experiment on.",
        "INFOPLIST_KEY_NSAccessoryTrackingUsageDescription":
            "OpenVRLink sends the position of your controllers to SteamVR.",
        "INFOPLIST_KEY_NSHandsTrackingUsageDescription":
            "OpenVRLink sends the position of your hands to SteamVR.",
        "INFOPLIST_KEY_GCSupportsControllerUserInteraction": "YES",
    }
    if bundle_id == OWN_BUNDLE_ID:
        target_settings["CODE_SIGN_ENTITLEMENTS"] = "OpenVRLink.entitlements"
    debug = dict(target_settings, SWIFT_OPTIMIZATION_LEVEL="-Onone", ONLY_ACTIVE_ARCH="YES",
                 DEBUG_INFORMATION_FORMAT="dwarf")
    release = dict(target_settings, SWIFT_OPTIMIZATION_LEVEL="-O")

    text = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{}};
	objectVersion = 60;
	objects = {{
{build_files}{product_build_files}{file_refs}{resource_refs}{resource_build_files}		{resource_group} = {{isa = PBXGroup; children = ({"".join(object_id('resref' + name) + ", " for name in resources)}); path = Resources; sourceTree = "<group>"; }};
		{resources_phase} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({"".join(object_id('resbuild' + name) + ", " for name in resources)}{assets_build}, ); runOnlyForDeploymentPostprocessing = 0; }};
		{assets} = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};
		{assets_build} = {{isa = PBXBuildFile; fileRef = {assets}; }};
		{plist} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
		{product} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{main_group} = {{isa = PBXGroup; children = ({source_group}, {resource_group}, {assets}, {plist}, {products_group}, ); sourceTree = "<group>"; }};
		{source_group} = {{isa = PBXGroup; children = ({", ".join(object_id('ref' + name) for name in sources)}, ); path = Sources; sourceTree = "<group>"; }};
		{products_group} = {{isa = PBXGroup; children = ({product}, ); name = Products; sourceTree = "<group>"; }};
		{sources_phase} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(object_id('build' + name) for name in sources)}, ); runOnlyForDeploymentPostprocessing = 0; }};
		{frameworks_phase} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({", ".join(object_id('pbuild' + name) for name in PACKAGE_PRODUCTS)}, ); runOnlyForDeploymentPostprocessing = 0; }};
		{target} = {{isa = PBXNativeTarget; buildConfigurationList = {object_id('target-configs')}; buildPhases = ({sources_phase}, {frameworks_phase}, {resources_phase}, ); buildRules = (); dependencies = (); name = {NAME}; packageProductDependencies = ({", ".join(object_id('dep' + name) for name in PACKAGE_PRODUCTS)}, ); productName = {NAME}; productReference = {product}; productType = "com.apple.product-type.application"; }};
		{project} = {{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 1600; }}; buildConfigurationList = {object_id('project-configs')}; compatibilityVersion = "Xcode 15.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = {main_group}; packageReferences = ({package}, ); productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = ({target}, ); }};
		{package} = {{isa = XCLocalSwiftPackageReference; relativePath = ..; }};
{dependencies}{configuration('project-debug', 'Debug', {'CLANG_ENABLE_MODULES': 'YES'})}{configuration('project-release', 'Release', {'CLANG_ENABLE_MODULES': 'YES'})}{configuration('target-debug', 'Debug', debug)}{configuration('target-release', 'Release', release)}		{object_id('project-configs')} = {{isa = XCConfigurationList; buildConfigurations = ({object_id('project-debug')}, {object_id('project-release')}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};
		{object_id('target-configs')} = {{isa = XCConfigurationList; buildConfigurations = ({object_id('target-debug')}, {object_id('target-release')}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};
	}};
	rootObject = {project};
}}
"""
    directory = HERE / f"{NAME}.xcodeproj"
    directory.mkdir(exist_ok=True)
    (directory / "project.pbxproj").write_text(text)
    print(f"wrote {directory.name}: {len(sources)} sources, bundle id {bundle_id}, team {team or '(none found)'}")


if __name__ == "__main__":
    main()
