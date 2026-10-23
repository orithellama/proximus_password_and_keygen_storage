#!/usr/bin/env python3
"""Deterministic Xcode project generation with no third-party build dependency."""
from pathlib import Path
import hashlib
import json
import plistlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "ProximusPasswords.xcodeproj"
PROJECT.mkdir(exist_ok=True)
objects = {}

def ident(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

class Ref(str):
    pass

def add(key, **value):
    ref = Ref(ident(key))
    objects[ref] = value
    return ref

def render(value, depth=0):
    if isinstance(value, Ref): return str(value)
    if isinstance(value, str): return json.dumps(value)
    if isinstance(value, int): return str(value)
    if isinstance(value, list): return "(" + ", ".join(render(v, depth+1) for v in value) + ("," if value else "") + ")"
    if isinstance(value, dict): return "{\n" + "".join("\t"*(depth+1)+str(k)+" = "+render(v, depth+1)+";\n" for k,v in value.items()) + "\t"*depth+"}"
    raise TypeError(value)

def file(path, kind=None):
    return add("file:"+path, isa="PBXFileReference", path=path, sourceTree="<group>", lastKnownFileType=kind or "sourcecode.swift")

shared = sorted(str(p.relative_to(ROOT)) for p in (ROOT/"apps/Shared").glob("*.swift"))
provider = "apps/AutoFill/CredentialProviderViewController.swift"
provider_sources = [provider, "apps/Shared/Brand.swift"]
refs = {path:file(path) for path in shared+[provider]}
base = file("Config/Base.xcconfig", "text.xcconfig")
assets = file("apps/Assets.xcassets", "folder.assetcatalog")
ios_icons = [file(str(path.relative_to(ROOT)), "image.png") for path in sorted((ROOT/"apps/iOSIcons").glob("*.png"))]
brand_resources = [file("apps/Brand/ProximusWings.png", "image.png")] + [file(str(path.relative_to(ROOT)), "file") for path in sorted((ROOT/"apps/Fonts").glob("*"))]
privacy = file("Config/PrivacyInfo.xcprivacy", "text.xml")
package = add("package", isa="XCLocalSwiftPackageReference", relativePath=".")
products = []
targets = []
target_ids = {}

capabilities = {"ProvidesPasswords": True, "ProvidesPasskeys": True, "ShowsConfigurationUI": True}
for platform in ["macOS", "iOS"]:
    for extension in [True, False]:
        name = ("AutoFill" if extension else "ProximusPasswords") + "-" + platform
        info = {
            "CFBundleName": "Proximus AutoFill" if extension else "Proximus",
            "CFBundleDisplayName": "Proximus AutoFill" if extension else "Proximus",
            "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
            "CFBundlePackageType": "XPC!" if extension else "APPL", "CFBundleInfoDictionaryVersion":"6.0",
            "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            "ProximusAppGroup": "$(PROXIMUS_APP_GROUP)", "ProximusKeychainGroup":"$(PROXIMUS_KEYCHAIN_GROUP)",
            "ProximusSigningTeam": "$(DEVELOPMENT_TEAM)",
            "ProximusSourceRevision": "$(PROXIMUS_SOURCE_REVISION)",
            "ProximusSourceDirty": "$(PROXIMUS_SOURCE_DIRTY)",
            "ASCredentialProviderExtensionCapabilities": capabilities,
            "ITSAppUsesNonExemptEncryption": True,
            "NSFaceIDUsageDescription": "Use Face ID to unlock your vault, approve passkeys, and reveal wallet recovery details.",
            "UIAppFonts": ["SpaceGrotesk.ttf", "Sora.ttf"],
        }
        if extension:
            info["NSExtension"] = {"NSExtensionPointIdentifier":"com.apple.authentication-services-credential-provider-ui", "NSExtensionPrincipalClass":"$(PRODUCT_MODULE_NAME).CredentialProviderViewController", "NSExtensionAttributes":{"ASCredentialProviderExtensionCapabilities":capabilities}}
        else:
            info.update({"CFBundleURLTypes":[{"CFBundleURLName":"org.proximus.passwords.pairing", "CFBundleURLSchemes":["proximus"]}], "NSLocalNetworkUsageDescription":"Pair and sync your encrypted Proximus vault with nearby devices you approve.", "NSBonjourServices":["_proximus-pair._tcp", "_proximus-sync._tcp"], "NSCameraUsageDescription":"Scan a Proximus device pairing QR code. Camera images are not stored or uploaded."})
            if platform == "iOS":
                info.update({"UILaunchScreen":{}, "UIApplicationSceneManifest":{"UIApplicationSupportsMultipleScenes":False}, "UISupportedInterfaceOrientations":["UIInterfaceOrientationPortrait","UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"], "UISupportedInterfaceOrientations~ipad":["UIInterfaceOrientationPortrait","UIInterfaceOrientationPortraitUpsideDown","UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"]})
                info["CFBundleIcons"] = {"CFBundlePrimaryIcon":{"CFBundleIconFiles":["AppIcon60x60"],"UIPrerenderedIcon":False}}
                info["CFBundleIcons~ipad"] = {"CFBundlePrimaryIcon":{"CFBundleIconFiles":["AppIcon60x60","AppIcon76x76","AppIcon83.5x83.5"],"UIPrerenderedIcon":False}}
            else:
                info.update({"NSPrincipalClass":"NSApplication", "LSApplicationCategoryType":"public.app-category.productivity"})
        plistpath = "Config/"+name+"-Info.plist"
        (ROOT/plistpath).write_bytes(plistlib.dumps(info, sort_keys=True))
        entitlements = {"com.apple.security.application-groups":["$(PROXIMUS_APP_GROUP)"],"keychain-access-groups":["$(PROXIMUS_KEYCHAIN_GROUP)"],"com.apple.developer.authentication-services.autofill-credential-provider":True}
        if platform == "macOS":
            entitlements["com.apple.security.app-sandbox"] = True
            if not extension: entitlements.update({"com.apple.security.network.client":True,"com.apple.security.network.server":True,"com.apple.security.files.user-selected.read-write":True,"com.apple.security.files.bookmarks.app-scope":True})
        entitlementpath = "Config/"+name+".entitlements"
        (ROOT/entitlementpath).write_bytes(plistlib.dumps(entitlements, sort_keys=True))
        product = add("product:"+name, isa="PBXFileReference", explicitFileType="wrapper.app-extension" if extension else "wrapper.application", path=("ProximusAutoFill" if extension else "Proximus")+(".appex" if extension else ".app"), sourceTree="BUILT_PRODUCTS_DIR")
        products.append(product)
        dependency = add("package-product:"+name, isa="XCSwiftPackageProductDependency", package=package, productName="ProximusKit")
        frameworks = add("framework-phase:"+name, isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[add("link:"+name, isa="PBXBuildFile", productRef=dependency)], runOnlyForDeploymentPostprocessing=0)
        sources = add("sources:"+name, isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=[add("compile:"+name+path, isa="PBXBuildFile", fileRef=refs[path]) for path in (provider_sources if extension else shared)], runOnlyForDeploymentPostprocessing=0)
        resource_refs = brand_resources + ([privacy] if extension else ([assets,privacy] if platform == "macOS" else ios_icons + [privacy]))
        resources = add("resources:"+name, isa="PBXResourcesBuildPhase", buildActionMask=2147483647, files=[add("resource:"+name+str(ref), isa="PBXBuildFile", fileRef=ref) for ref in resource_refs], runOnlyForDeploymentPostprocessing=0)
        phases=[sources,frameworks,resources]
        deps=[]
        if not extension:
            extname="AutoFill-"+platform
            extproduct=Ref(ident("product:"+extname))
            embed=add("embed-file:"+name, isa="PBXBuildFile",fileRef=extproduct,settings={"ATTRIBUTES":["RemoveHeadersOnCopy"]})
            phases.append(add("embed:"+name,isa="PBXCopyFilesBuildPhase",buildActionMask=2147483647,dstPath="",dstSubfolderSpec=13,files=[embed],name="Embed App Extensions",runOnlyForDeploymentPostprocessing=0))
            proxy=add("proxy:"+name,isa="PBXContainerItemProxy",containerPortal=Ref(ident("project")),proxyType=1,remoteGlobalIDString=target_ids[extname],remoteInfo=extname)
            deps=[add("target-dependency:"+name,isa="PBXTargetDependency",target=target_ids[extname],targetProxy=proxy)]
        configs=[]
        for config in ["Debug","Release"]:
            settings={"PRODUCT_NAME":"ProximusAutoFill" if extension else "Proximus", "PRODUCT_MODULE_NAME":"ProximusAutoFill" if extension else "ProximusPasswords", "PRODUCT_BUNDLE_IDENTIFIER":"$(PROXIMUS_BUNDLE_PREFIX)"+(".mac" if platform=="macOS" else ".ios")+(".autofill" if extension else ""), "INFOPLIST_FILE":plistpath,"CODE_SIGN_ENTITLEMENTS":entitlementpath,"SDKROOT":"macosx" if platform=="macOS" else "iphoneos","SUPPORTED_PLATFORMS":"macosx" if platform=="macOS" else "iphoneos iphonesimulator","SWIFT_OPTIMIZATION_LEVEL":"-Onone" if config=="Debug" else "-O","SWIFT_ACTIVE_COMPILATION_CONDITIONS":"DEBUG" if config=="Debug" else "","DEBUG_INFORMATION_FORMAT":"dwarf" if config=="Debug" else "dwarf-with-dsym","ONLY_ACTIVE_ARCH":"YES","ARCHS":"arm64","SKIP_INSTALL":"YES" if extension else "NO","APPLICATION_EXTENSION_API_ONLY":"YES" if extension else "NO"}
            if platform=="iOS":settings.update({"TARGETED_DEVICE_FAMILY":"1,2","SUPPORTS_MACCATALYST":"NO","SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD":"NO"})
            if not extension and platform == "macOS":settings["ASSETCATALOG_COMPILER_APPICON_NAME"]="AppIcon"
            configs.append(add("config:"+name+config,isa="XCBuildConfiguration",baseConfigurationReference=base,buildSettings=settings,name=config))
        configlist=add("config-list:"+name,isa="XCConfigurationList",buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName="Release")
        target=add("target:"+name,isa="PBXNativeTarget",buildConfigurationList=configlist,buildPhases=phases,buildRules=[],dependencies=deps,name=name,packageProductDependencies=[dependency],productName=name,productReference=product,productType="com.apple.product-type.app-extension" if extension else "com.apple.product-type.application")
        target_ids[name]=target;targets.append(target)

productgroup=add("products",isa="PBXGroup",children=products,name="Products",sourceTree="<group>")
group=add("main-group",isa="PBXGroup",children=list(refs.values())+ios_icons+brand_resources+[assets,privacy,base,productgroup],sourceTree="<group>")
projectconfigs=[add("project-config:"+name,isa="XCBuildConfiguration",baseConfigurationReference=base,buildSettings={},name=name) for name in ["Debug","Release"]]
configlist=add("project-config-list",isa="XCConfigurationList",buildConfigurations=projectconfigs,defaultConfigurationIsVisible=0,defaultConfigurationName="Release")
project=add("project",isa="PBXProject",attributes={"LastUpgradeCheck":"1610","BuildIndependentTargetsInParallel":"YES","TargetAttributes":{str(t):{"CreatedOnToolsVersion":"16.1"} for t in targets}},buildConfigurationList=configlist,compatibilityVersion="Xcode 14.0",developmentRegion="en",hasScannedForEncodings=0,knownRegions=["en","Base"],mainGroup=group,packageReferences=[package],productRefGroup=productgroup,projectDirPath="",projectRoot="",targets=targets)
document={"archiveVersion":1,"classes":{},"objectVersion":60,"objects":objects,"rootObject":project}
(PROJECT/"project.pbxproj").write_text("// !$*UTF8*$!\n"+render(document)+"\n")
schemedir=PROJECT/"xcshareddata/xcschemes";schemedir.mkdir(parents=True,exist_ok=True)
for platform in ["macOS","iOS"]:
    name="ProximusPasswords-"+platform
    scheme=ET.Element("Scheme",LastUpgradeVersion="1610",version="1.3")
    build=ET.SubElement(scheme,"BuildAction",parallelizeBuildables="YES",buildImplicitDependencies="YES")
    entry=ET.SubElement(ET.SubElement(build,"BuildActionEntries"),"BuildActionEntry",buildForTesting="YES",buildForRunning="YES",buildForProfiling="YES",buildForArchiving="YES",buildForAnalyzing="YES")
    attrs={"BuildableIdentifier":"primary","BlueprintIdentifier":str(target_ids[name]),"BuildableName":"Proximus.app","BlueprintName":name,"ReferencedContainer":"container:ProximusPasswords.xcodeproj"}
    ET.SubElement(entry,"BuildableReference",**attrs)
    launch=ET.SubElement(scheme,"LaunchAction",buildConfiguration="Debug",selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB",launchStyle="0",useCustomWorkingDirectory="NO",ignoresPersistentStateOnLaunch="NO",debugDocumentVersioning="YES",debugServiceExtension="internal",allowLocationSimulation="YES")
    ET.SubElement(ET.SubElement(launch,"BuildableProductRunnable",runnableDebuggingMode="0"),"BuildableReference",**attrs)
    ET.SubElement(scheme,"ArchiveAction",buildConfiguration="Release",revealArchiveInOrganizer="YES")
    ET.indent(scheme)
    ET.ElementTree(scheme).write(schemedir/(name+".xcscheme"),encoding="UTF-8",xml_declaration=True)
print("Generated ProximusPasswords.xcodeproj (macOS, iPhone, iPad, and AutoFill targets)")
