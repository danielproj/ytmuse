#!/usr/bin/env python3
"""Deterministic, dependency-free Xcode project generation (checked-in output)."""
from pathlib import Path
import hashlib, json
root=Path(__file__).resolve().parents[1]
objects={}
def uid(s): return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
def add(key, body): objects[uid(key)]=body; return uid(key)
def ref(key): return uid(key)
appfile=add('appfile','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Sources/NativeMusicApp.swift; sourceTree = "<group>";')
testfile=add('testfile','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ../Tests/NativeMusicUITests/NativeMusicUITests.swift; sourceTree = "<group>";')
appbuild=add('appbuild',f'isa = PBXBuildFile; fileRef = {appfile};')
# W24: the app's App Shortcuts and AppIntentsPackage declaration. The intents themselves live in the SystemIntegration package (in-process, no extension).
shortcutsfile=add('shortcutsfile','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Sources/NativeMusicShortcuts.swift; sourceTree = "<group>";')
shortcutsbuild=add('shortcutsbuild',f'isa = PBXBuildFile; fileRef = {shortcutsfile};')
# W25: the two files that name the real system surfaces (WidgetCenter, the App Group container, the Spotlight index). Only the app target compiles them.
widgetSupportFile=add('widgetsupportfile','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Sources/SystemWidgetSupport.swift; sourceTree = "<group>";')
widgetSupportBuild=add('widgetsupportbuild',f'isa = PBXBuildFile; fileRef = {widgetSupportFile};')
spotlightSupportFile=add('spotlightsupportfile','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Sources/SystemSearchableIndex.swift; sourceTree = "<group>";')
spotlightSupportBuild=add('spotlightsupportbuild',f'isa = PBXBuildFile; fileRef = {spotlightSupportFile};')
testbuild=add('testbuild',f'isa = PBXBuildFile; fileRef = {testfile};')
appProduct=add('appProduct','isa = PBXFileReference; explicitFileType = wrapper.application; path = YTMuse.app; sourceTree = BUILT_PRODUCTS_DIR;')
testProduct=add('testProduct','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = NativeMusicUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
package=add('package','isa = XCLocalSwiftPackageReference; relativePath = ../Packages/NativeMusic;')
product=add('shellproduct',f'isa = XCSwiftPackageProductDependency; package = {package}; productName = AppShell;')
framework=add('framework',f'isa = PBXBuildFile; productRef = {product};')
# The app target is the composition root for the signed Music client; UI modules never import the adapter.
adapterProduct=add('adapterproduct',f'isa = XCSwiftPackageProductDependency; package = {package}; productName = YouTubeMusicAdapter;')
adapterFramework=add('adapterframework',f'isa = PBXBuildFile; productRef = {adapterProduct};')
# W24: the app names SystemIntegration directly because it declares the AppIntentsPackage and the App Shortcuts that use its intents.
integrationProduct=add('integrationproduct',f'isa = XCSwiftPackageProductDependency; package = {package}; productName = SystemIntegration;')
integrationFramework=add('integrationframework',f'isa = PBXBuildFile; productRef = {integrationProduct};')
# W25: the app links WidgetShared directly (it writes the snapshot, installs the button receiver and declares the intent package); the widget extension is a
# second target built from Extensions/Sources/NativeMusicWidget and embedded into Contents/PlugIns by a script phase that YTMUSE_EMBED_WIDGET=NO turns off.
widgetSharedProduct=add('widgetsharedproduct',f'isa = XCSwiftPackageProductDependency; package = {package}; productName = WidgetShared;')
widgetSharedFramework=add('widgetsharedframework',f'isa = PBXBuildFile; productRef = {widgetSharedProduct};')
widgetMainFile=add('widgetmainfile','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ../Extensions/Sources/NativeMusicWidget/NativeMusicWidgetBundle.swift; sourceTree = "<group>";')
widgetMainBuild=add('widgetmainbuild',f'isa = PBXBuildFile; fileRef = {widgetMainFile};')
widgetProduct=add('widgetProduct','isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = NativeMusicWidget.appex; sourceTree = BUILT_PRODUCTS_DIR;')
widgetSharedForWidget=add('widgetsharedproductwidget',f'isa = XCSwiftPackageProductDependency; package = {package}; productName = WidgetShared;')
widgetFrameworkForWidget=add('widgetsharedframeworkwidget',f'isa = PBXBuildFile; productRef = {widgetSharedForWidget};')
add('widgetSources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({widgetMainBuild},); runOnlyForDeploymentPostprocessing = 0;')
add('widgetFrameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({widgetFrameworkForWidget},); runOnlyForDeploymentPostprocessing = 0;')
embedScript='\\"$SRCROOT/../scripts/embed-widget.sh\\"'
add('embedWidget',f'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); name = "Embed widget extension (YTMUSE_EMBED_WIDGET)"; outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = "{embedScript}";')
add('widgetproxy',f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("widget")}; remoteInfo = NativeMusicWidget;')
add('widgetdependency',f'isa = PBXTargetDependency; target = {ref("widget")}; targetProxy = {ref("widgetproxy")};')
for name,files in [('appSources',appbuild+', '+shortcutsbuild+', '+widgetSupportBuild+', '+spotlightSupportBuild),('testSources',testbuild)]: add(name,f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({files},); runOnlyForDeploymentPostprocessing = 0;')
add('appFrameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({framework}, {adapterFramework}, {integrationFramework}, {widgetSharedFramework},); runOnlyForDeploymentPostprocessing = 0;')
add('testFrameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
add('proxy',f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("app")}; remoteInfo = NativeMusic;')
add('dependency',f'isa = PBXTargetDependency; target = {ref("app")}; targetProxy = {ref("proxy")};')
base='ARCHS = arm64; SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 27.0; SWIFT_VERSION = 6.0; CLANG_ENABLE_MODULES = YES; CODE_SIGN_STYLE = Manual; CODE_SIGN_IDENTITY = "-"; ENABLE_HARDENED_RUNTIME = YES;'
for scope in ['project','app','test']:
 for config in ['Debug','Release']:
  settings=base
  if scope=='project': settings+=' SWIFT_OPTIMIZATION_LEVEL = '+('"-Onone";' if config=='Debug' else '"-O";')
  else:
   settings+=' GENERATE_INFOPLIST_FILE = YES; CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 0.0.1;'
   if scope=='app': settings+=' GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Info.plist; CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO; CODE_SIGN_ENTITLEMENTS = NativeMusic-adhoc.entitlements; PRODUCT_NAME = YTMuse; PRODUCT_BUNDLE_IDENTIFIER = local.native-music.development; INFOPLIST_KEY_CFBundleDisplayName = "YTMuse"; INFOPLIST_KEY_CFBundleName = "YTMuse"; INFOPLIST_KEY_CFBundleIconFile = YTMuse; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.music"; COMBINE_HIDPI_IMAGES = NO; ASSETCATALOG_COMPILER_APPICON_NAME = YTMuse;'
   else: settings+=' ENABLE_HARDENED_RUNTIME = NO; PRODUCT_NAME = NativeMusicUITests; PRODUCT_BUNDLE_IDENTIFIER = local.native-music.development.uitests; TEST_TARGET_NAME = NativeMusic;'
  add(scope+config,f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {config};')
 add(scope+'configs',f'isa = XCConfigurationList; buildConfigurations = ({ref(scope+"Debug")}, {ref(scope+"Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
brandBuilds=[]
brandRefs=[]
for filename in ['Glass-v2/YTMuse.icon','Glass-v2/YTMuseGlass.icns','YTMuseMenuTemplate.png','YTMuseMenuTemplate@2x.png']:
 file=add('brandfile'+filename,f'isa = PBXFileReference; lastKnownFileType = {"folder.icon" if filename.endswith(".icon") else "image.icns" if filename.endswith(".icns") else "image.png"}; path = "../Resources/Brand/{filename}"; sourceTree = "<group>";')
 brandRefs.append(file)
 brandBuilds.append(add('brandbuild'+filename,f'isa = PBXBuildFile; fileRef = {file};'))
catalog=add('catalogfile','isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = "../Resources/Localizable.xcstrings"; sourceTree = "<group>";')
brandRefs.append(catalog)
brandBuilds.append(add('catalogbuild',f'isa = PBXBuildFile; fileRef = {catalog};'))
# W26: the AppleScript dictionary (Info.plist OSAScriptingDefinition names it).
sdef=add('sdeffile','isa = PBXFileReference; lastKnownFileType = text.xml; path = "../Resources/YTMuse.sdef"; sourceTree = "<group>";')
brandRefs.append(sdef)
brandBuilds.append(add('sdefbuild',f'isa = PBXBuildFile; fileRef = {sdef};'))
# W24: App Shortcuts phrases, each with the app name, in their own String Catalog.
shortcutCatalog=add('shortcutcatalogfile','isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = "../Resources/AppShortcuts.xcstrings"; sourceTree = "<group>";')
brandRefs.append(shortcutCatalog)
brandBuilds.append(add('shortcutcatalogbuild',f'isa = PBXBuildFile; fileRef = {shortcutCatalog};'))
add('appResources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(brandBuilds)},); runOnlyForDeploymentPostprocessing = 0;')
for config in ['Debug','Release']:
 settings=base+' GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = ../Extensions/NativeMusicWidget-Info.plist; CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO; CODE_SIGN_ENTITLEMENTS = ../Extensions/NativeMusicWidget-adhoc.entitlements; PRODUCT_NAME = NativeMusicWidget; PRODUCT_BUNDLE_IDENTIFIER = local.native-music.development.widget; CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 0.0.1; SKIP_INSTALL = YES; APPLICATION_EXTENSION_API_ONLY = YES; ENABLE_DEBUG_DYLIB = NO; ENABLE_PREVIEWS = NO; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks";'
 add('widget'+config,f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {config};')
add('widgetconfigs',f'isa = XCConfigurationList; buildConfigurations = ({ref("widgetDebug")}, {ref("widgetRelease")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('widget',f'isa = PBXNativeTarget; buildConfigurationList = {ref("widgetconfigs")}; buildPhases = ({ref("widgetSources")}, {ref("widgetFrameworks")},); buildRules = (); dependencies = (); name = NativeMusicWidget; packageProductDependencies = ({widgetSharedForWidget},); productName = NativeMusicWidget; productReference = {widgetProduct}; productType = "com.apple.product-type.app-extension";')
add('app',f'isa = PBXNativeTarget; buildConfigurationList = {ref("appconfigs")}; buildPhases = ({ref("appSources")}, {ref("appFrameworks")}, {ref("appResources")}, {ref("embedWidget")},); buildRules = (); dependencies = ({ref("widgetdependency")},); name = NativeMusic; packageProductDependencies = ({product}, {adapterProduct}, {integrationProduct}, {widgetSharedProduct},); productName = YTMuse; productReference = {appProduct}; productType = "com.apple.product-type.application";')
add('test',f'isa = PBXNativeTarget; buildConfigurationList = {ref("testconfigs")}; buildPhases = ({ref("testSources")}, {ref("testFrameworks")},); buildRules = (); dependencies = ({ref("dependency")},); name = NativeMusicUITests; productName = NativeMusicUITests; productReference = {testProduct}; productType = "com.apple.product-type.bundle.ui-testing";')
add('products',f'isa = PBXGroup; children = ({appProduct}, {testProduct}, {widgetProduct},); name = Products; sourceTree = "<group>";')
add('mainGroup',f'isa = PBXGroup; children = ({appfile}, {shortcutsfile}, {widgetSupportFile}, {spotlightSupportFile}, {widgetMainFile}, {testfile}, {",".join(brandRefs)}, {ref("products")},); sourceTree = "<group>";')
# W28: the regions are the manifest's exact locale list (47 base locales and the formatting variants), plus Base.
_manifest=json.loads((root/'Resources/LocalizationManifest.json').read_text())
knownRegions=', '.join(['en','Base']+[('"%s"'%l if '-' in l else l) for l in _manifest['baseLocales']+_manifest['formattingVariants'] if l!='en'])+','
add('project',f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2710; }}; buildConfigurationList = {ref("projectconfigs")}; compatibilityVersion = "Xcode 15.0"; developmentRegion = en; knownRegions = ({knownRegions}); mainGroup = {ref("mainGroup")}; packageReferences = ({package},); productRefGroup = {ref("products")}; projectDirPath = ""; projectRoot = ""; targets = ({ref("app")}, {ref("widget")}, {ref("test")},);')
# Explicit synthetic composition is a separate test-only application product.
hostfile=add('hostfile','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ../Tests/AccountSession/NativeAccountTestHost.swift; sourceTree = "<group>";')
hostbuild=add('hostbuild',f'isa = PBXBuildFile; fileRef = {hostfile};')
hostProduct=add('hostProduct','isa = PBXFileReference; explicitFileType = wrapper.application; path = NativeAccountTestHost.app; sourceTree = BUILT_PRODUCTS_DIR;')
hostFrameworks=[]
hostProducts=[]
for module in ['Features','AccountSession','Persistence','Domain','DesignSystem']:
 prod=add('hostproduct'+module,f'isa = XCSwiftPackageProductDependency; package = {package}; productName = {module};')
 hostProducts.append(prod)
 hostFrameworks.append(add('hostframework'+module,f'isa = PBXBuildFile; productRef = {prod};'))
add('hostSources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({hostbuild},); runOnlyForDeploymentPostprocessing = 0;')
add('hostFrameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({",".join(hostFrameworks)},); runOnlyForDeploymentPostprocessing = 0;')
for config in ['Debug','Release']:
 settings=base+' GENERATE_INFOPLIST_FILE = YES; PRODUCT_NAME = NativeAccountTestHost; PRODUCT_BUNDLE_IDENTIFIER = local.native-music.account-tests; CODE_SIGN_ENTITLEMENTS = ../Tests/AccountSession/TestHost.entitlements; INFOPLIST_KEY_CFBundleDisplayName = "YTMuse Account Tests";'
 add('host'+config,f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {config};')
add('hostconfigs',f'isa = XCConfigurationList; buildConfigurations = ({ref("hostDebug")}, {ref("hostRelease")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('host',f'isa = PBXNativeTarget; buildConfigurationList = {ref("hostconfigs")}; buildPhases = ({ref("hostSources")}, {ref("hostFrameworks")},); buildRules = (); dependencies = (); name = NativeAccountTestHost; packageProductDependencies = ({",".join(hostProducts)},); productName = NativeAccountTestHost; productReference = {hostProduct}; productType = "com.apple.product-type.application";')
add('hostproxy',f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("host")}; remoteInfo = NativeAccountTestHost;')
add('hostdependency',f'isa = PBXTargetDependency; target = {ref("host")}; targetProxy = {ref("hostproxy")};')
objects[ref('test')]=objects[ref('test')].replace(f'dependencies = ({ref("dependency")},);',f'dependencies = ({ref("dependency")}, {ref("hostdependency")},);')
objects[ref('project')]=objects[ref('project')].replace(f'{ref("test")},);',f'{ref("test")}, {ref("host")},);')
objects[ref('mainGroup')]=objects[ref('mainGroup')].replace(f'{testfile},',f'{testfile}, {hostfile},')
objects[ref('products')]=objects[ref('products')].replace(f'{testProduct},',f'{testProduct}, {hostProduct},')
p=root/'App/NativeMusic.xcodeproj/project.pbxproj'
p.write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n'+''.join(f'{k} = {{ {v} }};\n' for k,v in sorted(objects.items()))+f'}}; rootObject = {ref("project")}; }}\n')
def buildref(target,name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref(target)}" BuildableName="{name}" BlueprintName="{ "NativeMusic" if target=="app" else "NativeMusicUITests" }" ReferencedContainer="container:NativeMusic.xcodeproj"/>'
(root/'App/NativeMusic.xcodeproj/xcshareddata/xcschemes/NativeMusic.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildref('app','YTMuse.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildref('test','NativeMusicUITests.xctest')}</TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref('app','YTMuse.app')}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref('app','YTMuse.app')}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
