"""Generate a dependency-free Xcode app using the adjacent local Swift package."""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def uid(name):return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def q(value):return json.dumps(str(value))
objects=[]
def put(name,isa,props):objects.append('%s = {isa = %s; %s };'%(uid(name),isa,props))
def refs(names):return '('+','.join(uid(n) for n in names)+')'
files=sorted(p.relative_to(ROOT).as_posix() for p in (ROOT/'Sources/iOS').glob('*.swift'))
for f in files:
    put(f,'PBXFileReference','lastKnownFileType = sourcecode.swift; path = %s; sourceTree = SOURCE_ROOT;'%q(f))
    put('build:'+f,'PBXBuildFile','fileRef = %s;'%uid(f))
put('product','PBXFileReference','explicitFileType = wrapper.application; path = Baduanjin.app; sourceTree = BUILT_PRODUCTS_DIR;')
put('plist','PBXFileReference','lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = SOURCE_ROOT;')
put('package','XCLocalSwiftPackageReference','relativePath = ".";')
put('core','XCSwiftPackageProductDependency','package = %s; productName = BaduanjinCore;'%uid('package'))
put('corebuild','PBXBuildFile','productRef = %s;'%uid('core'))
put('sources','PBXSourcesBuildPhase','buildActionMask = 2147483647; files = %s; runOnlyForDeploymentPostprocessing = 0;'%refs(['build:'+f for f in files]))
put('frameworks','PBXFrameworksBuildPhase','buildActionMask = 2147483647; files = %s; runOnlyForDeploymentPostprocessing = 0;'%refs(['corebuild']))
put('resources','PBXResourcesBuildPhase','buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
put('products','PBXGroup','name = Products; children = %s; sourceTree = "<group>";'%refs(['product']))
put('main','PBXGroup','children = %s; sourceTree = "<group>";'%refs(files+['plist','products']))
common='SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = targeted; '
target='PRODUCT_NAME = Baduanjin; PRODUCT_BUNDLE_IDENTIFIER = dev.imulink.baduanjin.ios; INFOPLIST_FILE = Info.plist; GENERATE_INFOPLIST_FILE = NO; TARGETED_DEVICE_FAMILY = 1; CODE_SIGN_STYLE = Automatic; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SWIFT_EMIT_LOC_STRINGS = YES; '
for kind in ('project','target'):
    for config in ('Debug','Release'):
        flags='SWIFT_OPTIMIZATION_LEVEL = %s; DEBUG_INFORMATION_FORMAT = %s;'%('"-Onone"' if config=='Debug' else '"-O"','dwarf' if config=='Debug' else '"dwarf-with-dsym"')
        put(kind+config,'XCBuildConfiguration','name = %s; buildSettings = {%s};'%(config,common+flags+(target if kind=='target' else '')))
    put(kind+'configs','XCConfigurationList','buildConfigurations = %s; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;'%refs([kind+'Debug',kind+'Release']))
put('app','PBXNativeTarget','name = Baduanjin; productName = Baduanjin; productType = "com.apple.product-type.application"; productReference = %s; buildConfigurationList = %s; buildPhases = %s; dependencies = (); buildRules = (); packageProductDependencies = %s;'%(uid('product'),uid('targetconfigs'),refs(['sources','frameworks','resources']),refs(['core'])))
put('project','PBXProject','attributes = {LastUpgradeCheck = 2600;}; buildConfigurationList = %s; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; knownRegions = (zh_CN,en,Base); mainGroup = %s; productRefGroup = %s; projectDirPath = ""; projectRoot = ""; targets = %s; packageReferences = %s;'%(uid('projectconfigs'),uid('main'),uid('products'),refs(['app']),refs(['package'])))
project=ROOT/'Baduanjin.xcodeproj';project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+uid('project')+';}\n',encoding='utf8')
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
ref='<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%s" BuildableName="Baduanjin.app" BlueprintName="Baduanjin" ReferencedContainer="container:Baduanjin.xcodeproj"/>'%uid('app')
(schemes/'Baduanjin.xcscheme').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">%s</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
<LaunchAction buildConfiguration="Debug" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">%s</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">%s</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''%(ref,ref,ref),encoding='utf8')
print('Generated Xcode project:',len(files),'app sources; local BaduanjinCore package')
