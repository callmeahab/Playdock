#!/usr/bin/env python3
"""Regenerate the checked-in native Xcode project without third-party tools."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Playdock.xcodeproj"
objects = {}


def identity(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def obj(label, isa, **fields):
    key = identity(label)
    objects[key] = {"isa": isa, **fields}
    return key


def quote(value):
    if isinstance(value, dict):
        return "{ " + " ".join(f"{json.dumps(k)} = {quote(v)};" for k, v in value.items()) + " }"
    if isinstance(value, list):
        return "( " + ", ".join(quote(v) for v in value) + (", )" if value else ")")
    return json.dumps(str(value))


def configuration_list(name, settings):
    configs = []
    for mode in ["Debug", "Release"]:
        specific = {**settings}
        specific["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if mode == "Debug" else "-O"
        if mode == "Debug":
            specific["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG $(inherited)"
            specific["ENABLE_TESTABILITY"] = "YES"
        configs.append(obj(f"{name}/{mode}", "XCBuildConfiguration", name=mode, buildSettings=specific))
    return obj(f"{name}/configurations", "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


groups = []
source_refs = {}
for folder in ["Sources/Playdock", "Sources/PlaydockCore", "Tests/PlaydockCoreTests", "Sources/PlaydockNative", "Sources/PlaydockSteamIntegration"]:
    refs = []
    for path in sorted(p for p in (ROOT / folder).rglob("*") if p.suffix in (".swift", ".m", ".h")):
        relative = str(path.relative_to(ROOT))
        ref = obj(relative, "PBXFileReference", lastKnownFileType={".swift": "sourcecode.swift", ".m": "sourcecode.c.objc", ".h": "sourcecode.c.h"}[path.suffix], path=relative, sourceTree="SOURCE_ROOT")
        refs.append(ref)
        source_refs[relative] = ref
    groups.append(obj(folder, "PBXGroup", name=folder.split("/")[-1], children=refs, sourceTree="<group>"))

plist = obj("Info.plist", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="SOURCE_ROOT")
readme = obj("README.md", "PBXFileReference", lastKnownFileType="net.daringfireball.markdown", path="README.md", sourceTree="SOURCE_ROOT")
contributing = obj("CONTRIBUTING.md", "PBXFileReference", lastKnownFileType="net.daringfireball.markdown", path="CONTRIBUTING.md", sourceTree="SOURCE_ROOT")
license_refs = [obj(name, "PBXFileReference", lastKnownFileType="text", path=name, sourceTree="SOURCE_ROOT") for name in ["LICENSE", "NOTICE"]]
core_product = obj("core-product", "PBXFileReference", explicitFileType="archive.ar", path="libPlaydockCore.a", sourceTree="BUILT_PRODUCTS_DIR")
app_product = obj("app-product", "PBXFileReference", explicitFileType="wrapper.application", path="Playdock.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = obj("test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", path="PlaydockCoreTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
native_product = obj("native-product", "PBXFileReference", explicitFileType="compiled.mach-o.dylib", path="libPlaydockWineDisplay.dylib", sourceTree="BUILT_PRODUCTS_DIR")
bridge_product = obj("bridge-product", "PBXFileReference", explicitFileType="compiled.mach-o.executable", path="PlaydockSteamIntegration", sourceTree="BUILT_PRODUCTS_DIR")
products = obj("products", "PBXGroup", name="Products", children=[app_product, core_product, test_product, native_product, bridge_product], sourceTree="<group>")
assets = obj("assets", "PBXFileReference", lastKnownFileType="folder.assetcatalog", path="Assets.xcassets", sourceTree="SOURCE_ROOT")
main_group = obj("main-group", "PBXGroup", children=groups + [assets, plist, readme, contributing] + license_refs + [products], sourceTree="<group>")

common = {
    "MACOSX_DEPLOYMENT_TARGET": "13.0", "SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete", "CLANG_ENABLE_MODULES": "YES", "SDKROOT": "macosx",
    "CODE_SIGN_STYLE": "Automatic", "CODE_SIGN_IDENTITY": "-", "DEVELOPMENT_TEAM": "", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "SWIFT_INCLUDE_PATHS": "$(inherited) $(BUILT_PRODUCTS_DIR)", "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1",
}
project_configs = configuration_list("project", common)


def sources_phase(name, prefix):
    builds = [obj(f"{name}/build/{path}", "PBXBuildFile", fileRef=ref) for path, ref in source_refs.items() if path.startswith(prefix) and not path.endswith(".h")]
    return obj(f"{name}/sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=builds, runOnlyForDeploymentPostprocessing="0")


def framework_phase(name, include_core):
    builds = [obj(f"{name}/link-core", "PBXBuildFile", fileRef=core_product)] if include_core else []
    return obj(f"{name}/frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=builds, runOnlyForDeploymentPostprocessing="0")


core_target = obj("core-target", "PBXNativeTarget", name="PlaydockCore", productName="PlaydockCore", productReference=core_product,
    productType="com.apple.product-type.library.static", buildPhases=[sources_phase("core", "Sources/PlaydockCore/"), framework_phase("core", False)],
    buildRules=[], dependencies=[], buildConfigurationList=configuration_list("core", {"PRODUCT_NAME": "$(TARGET_NAME)", "DEFINES_MODULE": "YES", "SKIP_INSTALL": "YES"}))

proxy = obj("core-proxy", "PBXContainerItemProxy", containerPortal=identity("project"), proxyType="1", remoteGlobalIDString=core_target, remoteInfo="PlaydockCore")
core_dependency = obj("core-dependency", "PBXTargetDependency", target=core_target, targetProxy=proxy)
native_target = obj("native-target", "PBXNativeTarget", name="PlaydockWineDisplay", productName="PlaydockWineDisplay", productReference=native_product,
    productType="com.apple.product-type.library.dynamic", buildPhases=[sources_phase("native", "Sources/PlaydockNative/"), framework_phase("native", False)],
    buildRules=[], dependencies=[], buildConfigurationList=configuration_list("native", {
        "PRODUCT_NAME": "PlaydockWineDisplay", "EXECUTABLE_PREFIX": "lib", "CLANG_ENABLE_OBJC_ARC": "YES",
        "ARCHS": "arm64 x86_64", "ONLY_ACTIVE_ARCH": "NO",
        "OTHER_LDFLAGS": "$(inherited) -framework Cocoa -framework ApplicationServices -framework QuartzCore -framework OpenGL -framework IOSurface", "ENABLE_HARDENED_RUNTIME": "NO",
        "SKIP_INSTALL": "YES", "DYLIB_INSTALL_NAME_BASE": "@rpath",
    }))
bridge_target = obj("bridge-target", "PBXNativeTarget", name="PlaydockSteamIntegration", productName="PlaydockSteamIntegration", productReference=bridge_product,
    productType="com.apple.product-type.tool", buildPhases=[sources_phase("bridge", "Sources/PlaydockSteamIntegration/"), framework_phase("bridge", True)],
    buildRules=[], dependencies=[core_dependency], buildConfigurationList=configuration_list("bridge", {
        "PRODUCT_NAME": "$(TARGET_NAME)", "SKIP_INSTALL": "YES", "ENABLE_HARDENED_RUNTIME": "YES",
    }))
bridge_proxy = obj("bridge-proxy", "PBXContainerItemProxy", containerPortal=identity("project"), proxyType="1", remoteGlobalIDString=bridge_target, remoteInfo="PlaydockSteamIntegration")
bridge_dependency = obj("bridge-dependency", "PBXTargetDependency", target=bridge_target, targetProxy=bridge_proxy)
bridge_embed_build = obj("app/embed-bridge", "PBXBuildFile", fileRef=bridge_product, settings={"ATTRIBUTES": ["CodeSignOnCopy"]})
bridge_embed = obj("app/embed-bridge-phase", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="", dstSubfolderSpec="6", files=[bridge_embed_build], runOnlyForDeploymentPostprocessing="0")
native_proxy = obj("native-proxy", "PBXContainerItemProxy", containerPortal=identity("project"), proxyType="1", remoteGlobalIDString=native_target, remoteInfo="PlaydockWineDisplay")
native_dependency = obj("native-dependency", "PBXTargetDependency", target=native_target, targetProxy=native_proxy)
embed_build = obj("app/embed-native", "PBXBuildFile", fileRef=native_product, settings={"ATTRIBUTES": ["CodeSignOnCopy"]})
embed = obj("app/embed", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="", dstSubfolderSpec="10", files=[embed_build], runOnlyForDeploymentPostprocessing="0")
asset_build = obj("app/build/assets", "PBXBuildFile", fileRef=assets)
license_builds = [obj(f"app/build/{name}", "PBXBuildFile", fileRef=ref) for name, ref in zip(["LICENSE", "NOTICE"], license_refs)]
resources = obj("app/resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[asset_build] + license_builds, runOnlyForDeploymentPostprocessing="0")
bridge_resources = obj("app/bridge-resources", "PBXShellScriptBuildPhase", buildActionMask="2147483647", alwaysOutOfDate="1", files=[],
    inputPaths=["$(SRCROOT)/Scripts/prepare_steam_bridge.py", "$(SRCROOT)/BridgeComponents/release.json", "$(SRCROOT)/BridgeComponents/Licenses"],
    outputPaths=["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/SteamBridge/release.json"],
    name="Build Steam integration", runOnlyForDeploymentPostprocessing="0", shellPath="/bin/sh",
    shellScript='set -eu\n/usr/bin/python3 "$SRCROOT/Scripts/prepare_steam_bridge.py" --output "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/SteamBridge"\n')
app_target = obj("app-target", "PBXNativeTarget", name="Playdock", productName="Playdock", productReference=app_product,
    productType="com.apple.product-type.application", buildPhases=[sources_phase("app", "Sources/Playdock/"), framework_phase("app", True), resources, bridge_resources, embed, bridge_embed],
    buildRules=[], dependencies=[core_dependency, native_dependency, bridge_dependency], buildConfigurationList=configuration_list("app", {
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "app.playdock.mac", "INFOPLIST_FILE": "Info.plist",
        "SWIFT_OBJC_BRIDGING_HEADER": "Sources/Playdock/RemoteLayer.h", "CLANG_ENABLE_OBJC_ARC": "YES",
        "GENERATE_INFOPLIST_FILE": "NO", "ENABLE_APP_SANDBOX": "NO", "ENABLE_HARDENED_RUNTIME": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks", "COMBINE_HIDPI_IMAGES": "YES",
    }))
test_target = obj("test-target", "PBXNativeTarget", name="PlaydockCoreTests", productName="PlaydockCoreTests", productReference=test_product,
    productType="com.apple.product-type.bundle.unit-test", buildPhases=[sources_phase("test", "Tests/PlaydockCoreTests/"), framework_phase("test", True)],
    buildRules=[], dependencies=[core_dependency], buildConfigurationList=configuration_list("test", {
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "app.playdock.mac.coretests", "GENERATE_INFOPLIST_FILE": "YES",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @loader_path/../Frameworks @executable_path/../Frameworks", "SKIP_INSTALL": "YES",
    }))

project = obj("project", "PBXProject", attributes={"LastUpgradeCheck": "1500", "BuildIndependentTargetsInParallel": "YES"},
    buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings="0",
    knownRegions=["en", "Base"], mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app_target, core_target, test_target, native_target, bridge_target])
PROJECT.mkdir(exist_ok=True)
lines = ["// !$*UTF8*$!", "{", "archiveVersion = 1;", "classes = {};", "objectVersion = 56;", "objects = {"]
lines.extend(f"{key} = {quote(value)};" for key, value in objects.items())
lines.extend(["};", f"rootObject = {project};", "}"])
(PROJECT / "project.pbxproj").write_text("\n".join(lines) + "\n")


def buildable(target, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}" BlueprintName="{name.removesuffix(".app").removesuffix(".xctest")}" ReferencedContainer="container:Playdock.xcodeproj"/>'


app_ref = buildable(app_target, "Playdock.app")
test_ref = buildable(test_target, "PlaydockCoreTests.xctest")
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
scheme_dir = PROJECT / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / "Playdock.xcscheme").write_text(scheme)
