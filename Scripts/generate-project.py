#!/usr/bin/env python3
"""Generate the small native Xcode project without a global generator dependency."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "App"
PROJECT = APP / "DB3.xcodeproj"
PROJECT.mkdir(exist_ok=True)
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value))
objects = {}
def add(name, body): objects[uid(name)] = body; return uid(name)
sources = sorted((APP / "DB3App").glob("*.swift"))
refs = []
buildrefs = []
for path in sources:
    key = path.name
    ref = add(key, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q("DB3App/" + key)}; sourceTree = "<group>";')
    refs.append(ref)
    buildrefs.append(add("build-" + key, f'isa = PBXBuildFile; fileRef = {ref};'))
product = add("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = db3.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = add("products", f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
group = add("group", f'isa = PBXGroup; children = ({",".join(refs + [products])},); sourceTree = "<group>";')
sourcephase = add("sourcephase", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(buildrefs)},); runOnlyForDeploymentPostprocessing = 0;')
package = add("package", 'isa = XCLocalSwiftPackageReference; relativePath = ../Packages/DB3Kit;')
dependencies = []
frameworks = []
for name in ("DB3Core", "DB3Postgres", "DB3Results", "DB3Editor", "DB3Grid", "DB3Projects"):
    dependency = add("dep-" + name, f'isa = XCSwiftPackageProductDependency; package = {package}; productName = {name};')
    dependencies.append(dependency)
    frameworks.append(add("framework-" + name, f'isa = PBXBuildFile; productRef = {dependency};'))
frameworkphase = add("frameworkphase", f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({",".join(frameworks)},); runOnlyForDeploymentPostprocessing = 0;')
embed = add("embedphase", 'isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); name = "Embed PostgreSQL"; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = "python3 \\\"$SRCROOT/../Scripts/embed-postgres.py\\\" \\\"$TARGET_BUILD_DIR/$WRAPPER_NAME\\\""; alwaysOutOfDate = 1;')
# Use JSON to correctly quote the Xcode shell script, including shell variable syntax.
objects[embed] = 'isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); name = "Embed PostgreSQL"; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = ' + q('python3 "$SRCROOT/../Scripts/embed-postgres.py" "$TARGET_BUILD_DIR/$WRAPPER_NAME"') + '; alwaysOutOfDate = 1;'
configs = {}
for scope in ("project", "app"):
    ids = []
    for name in ("Debug", "Release"):
        settings = {
            "MACOSX_DEPLOYMENT_TARGET": "26.0", "SDKROOT": "macosx", "SWIFT_VERSION": "6.0", "ARCHS": "arm64",
            "SWIFT_STRICT_CONCURRENCY": "complete", "CLANG_ENABLE_MODULES": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym",
        }
        if scope == "app": settings.update({
            "PRODUCT_NAME": "db3", "PRODUCT_BUNDLE_IDENTIFIER": "app.db3.workbench", "GENERATE_INFOPLIST_FILE": "YES",
            "INFOPLIST_KEY_CFBundleDisplayName": "db3", "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.developer-tools",
            "INFOPLIST_KEY_NSHumanReadableCopyright": "Author: Ariel Patschiki",
            "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1", "CODE_SIGN_STYLE": "Automatic",
            # Ad-hoc development signatures have no Team ID. Hardened runtime
            # library validation rejects our ad-hoc native dependencies at launch.
            # Distribution must enable runtime and sign every library with the
            # same Developer ID as the application.
            "CODE_SIGN_IDENTITY": "-", "ENABLE_HARDENED_RUNTIME": "NO", "ENABLE_APP_SANDBOX": "NO",
            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks", "SWIFT_EMIT_LOC_STRINGS": "YES",
        })
        settings_text = " ".join(f'{k} = {q(v)};' for k, v in settings.items())
        ids.append(add(scope + name, f'isa = XCBuildConfiguration; buildSettings = {{{settings_text}}}; name = {name};'))
    configs[scope] = add(scope + "configs", f'isa = XCConfigurationList; buildConfigurations = ({",".join(ids)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = add("target", f'isa = PBXNativeTarget; buildConfigurationList = {configs["app"]}; buildPhases = ({sourcephase},{frameworkphase},{embed},); buildRules = (); dependencies = (); name = db3; productName = db3; productReference = {product}; productType = "com.apple.product-type.application"; packageProductDependencies = ({",".join(dependencies)},);')
project = add("project", f'isa = PBXProject; attributes = {{LastUpgradeCheck = 2660;}}; buildConfigurationList = {configs["project"]}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},); packageReferences = ({package},);')
text = '// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n' + '\n'.join(f'{key} = {{{value}}};' for key, value in objects.items()) + f'\n}}; rootObject = {project};}}\n'
(PROJECT / "project.pbxproj").write_text(text)
schemes = PROJECT / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "db3.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="db3.app" BlueprintName="db3" ReferencedContainer="container:DB3.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="db3.app" BlueprintName="db3" ReferencedContainer="container:DB3.xcodeproj"/></BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(PROJECT)
