#!/usr/bin/env python3
"""Generate dependency-free native app/core/helper Xcode targets from the source tree."""
from pathlib import Path
import json
root = Path(__file__).resolve().parent.parent
objects = []
next_id = 100

def ident(n): return f'{n:024X}'
def obj(body):
    global next_id
    next_id += 1
    key = ident(next_id); objects.append(f'{key} = {{ {body} }};'); return key
def q(s): return json.dumps(str(s))
def arr(items): return '(' + ', '.join(items) + ')'
def reference(path, kind): return obj(f'isa = PBXFileReference; path = {q(path)}; lastKnownFileType = {kind}; sourceTree = SOURCE_ROOT;')
def phase(kind, refs):
    files = [obj(f'isa = PBXBuildFile; fileRef = {ref};') for ref in refs]
    return obj(f'isa = {kind}; buildActionMask = 2147483647; files = {arr(files)}; runOnlyForDeploymentPostprocessing = 0;')
def configurations(settings):
    configs = []
    for name in ['Debug', 'Release']:
        values = dict(settings, SWIFT_OPTIMIZATION_LEVEL='-Onone' if name=='Debug' else '-O')
        body = ' '.join(f'{key} = {q(value)};' for key,value in values.items())
        configs.append(obj(f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ {body} }};'))
    return obj(f'isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
common = {'ARCHS':'arm64 x86_64','ONLY_ACTIVE_ARCH':'NO','MACOSX_DEPLOYMENT_TARGET':'14.0','SDKROOT':'macosx','SWIFT_VERSION':'6.0','ALWAYS_SEARCH_USER_PATHS':'NO','SWIFT_STRICT_CONCURRENCY':'complete','ENABLE_HARDENED_RUNTIME':'YES'}
app_files = [reference(p.relative_to(root), 'sourcecode.swift') for p in sorted((root/'Sources/Maschinery').glob('*.swift'))]
core_files = [reference(p.relative_to(root), 'sourcecode.swift') for p in sorted((root/'Sources/MaschineryCore').glob('*.swift'))]
c_file = reference('Sources/SafeArchive/SafeArchive.c','sourcecode.c.c')
helper_files = [reference('Sources/MaschineryHelper/main.swift','sourcecode.swift')]
icon = reference('Resources/AppIcon.icns','image.icns')
catalogue = reference('Sources/MaschineryCore/Resources/ExpansionCatalogue.json','text.json')
daemon = reference('Helper/local.maschinery.helper.plist','text.plist.xml')
app_product = obj('isa = PBXFileReference; explicitFileType = wrapper.application; path = "Maschinery.app"; sourceTree = BUILT_PRODUCTS_DIR;')
core_product = obj('isa = PBXFileReference; explicitFileType = archive.ar; path = libMaschineryCore.a; sourceTree = BUILT_PRODUCTS_DIR;')
helper_product = obj('isa = PBXFileReference; explicitFileType = compiled.mach-o.executable; path = MaschineryHelper; sourceTree = BUILT_PRODUCTS_DIR;')
core_sources = phase('PBXSourcesBuildPhase',core_files+[c_file])
core_config = configurations(dict(common, PRODUCT_NAME='MaschineryCore', DEFINES_MODULE='YES', SKIP_INSTALL='YES', SWIFT_INCLUDE_PATHS='$(SRCROOT)/Sources/SafeArchive/include', HEADER_SEARCH_PATHS='$(SRCROOT)/Sources/SafeArchive/include'))
core = obj(f'isa = PBXNativeTarget; name = MaschineryCore; productName = MaschineryCore; productReference = {core_product}; productType = "com.apple.product-type.library.static"; buildConfigurationList = {core_config}; buildPhases = ({core_sources}); buildRules = (); dependencies = ();')
def dependency(target): return obj(f'isa = PBXTargetDependency; target = {target};')
helper_sources = phase('PBXSourcesBuildPhase',helper_files)
helper_link = phase('PBXFrameworksBuildPhase',[core_product])
helper_config = configurations(dict(common, PRODUCT_NAME='MaschineryHelper', PRODUCT_BUNDLE_IDENTIFIER='local.maschinery.helper', CODE_SIGN_STYLE='Automatic', GENERATE_INFOPLIST_FILE='YES', CREATE_INFOPLIST_SECTION_IN_BINARY='YES', SKIP_INSTALL='YES', SWIFT_INCLUDE_PATHS='$(SRCROOT)/Sources/SafeArchive/include'))
helper = obj(f'isa = PBXNativeTarget; name = MaschineryHelper; productName = MaschineryHelper; productReference = {helper_product}; productType = "com.apple.product-type.tool"; buildConfigurationList = {helper_config}; buildPhases = ({helper_sources}, {helper_link}); buildRules = (); dependencies = ({dependency(core)});')
app_sources = phase('PBXSourcesBuildPhase',app_files)
app_link = phase('PBXFrameworksBuildPhase',[core_product])
app_resources = phase('PBXResourcesBuildPhase',[icon,catalogue])
copy_helper_file = obj(f'isa = PBXBuildFile; fileRef = {helper_product}; settings = {{ ATTRIBUTES = (CodeSignOnCopy); }};')
copy_helper = obj(f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = Contents/Library/LaunchServices; dstSubfolderSpec = 1; files = ({copy_helper_file}); runOnlyForDeploymentPostprocessing = 0; name = "Embed Privileged Helper";')
copy_daemon_file = obj(f'isa = PBXBuildFile; fileRef = {daemon};')
copy_daemon = obj(f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = Contents/Library/LaunchDaemons; dstSubfolderSpec = 1; files = ({copy_daemon_file}); runOnlyForDeploymentPostprocessing = 0; name = "Embed Launch Daemon";')
app_config = configurations(dict(common, PRODUCT_NAME='Maschinery', PRODUCT_BUNDLE_IDENTIFIER='local.maschinery.app', CODE_SIGN_STYLE='Automatic', GENERATE_INFOPLIST_FILE='YES', INFOPLIST_KEY_CFBundleIconFile='AppIcon', INFOPLIST_KEY_LSApplicationCategoryType='public.app-category.music', MARKETING_VERSION='1.0.2', CURRENT_PROJECT_VERSION='1', SWIFT_INCLUDE_PATHS='$(SRCROOT)/Sources/SafeArchive/include'))
app = obj(f'isa = PBXNativeTarget; name = Maschinery; productName = Maschinery; productReference = {app_product}; productType = "com.apple.product-type.application"; buildConfigurationList = {app_config}; buildPhases = ({app_sources}, {app_link}, {app_resources}, {copy_helper}, {copy_daemon}); buildRules = (); dependencies = ({dependency(core)}, {dependency(helper)});')
products = obj(f'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = ({app_product}, {core_product}, {helper_product});')
group = obj(f'isa = PBXGroup; sourceTree = "<group>"; children = {arr(app_files+core_files+helper_files+[c_file,icon,catalogue,daemon,products])};')
project_config = configurations(common)
project = obj(f'isa = PBXProject; buildConfigurationList = {project_config}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({app}, {core}, {helper});')
(root/'Maschinery.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+project+'; }\n')
