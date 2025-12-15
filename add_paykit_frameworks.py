#!/usr/bin/env python3
"""
Script to add PaykitMobile and PubkyNoise XCFrameworks to Bitkit iOS Xcode project.
"""

import re
import uuid
import sys

def generate_id():
    """Generate a 24-character hex ID like Xcode uses."""
    return ''.join([hex(ord(c))[2:].zfill(2).upper() for c in uuid.uuid4().hex[:12]])

def add_xcframework_to_project(project_path):
    """Add PaykitMobile and PubkyNoise XCFrameworks to the Xcode project."""
    
    # Read the project file
    with open(project_path, 'r') as f:
        content = f.read()
    
    # Generate unique IDs
    paykit_file_ref_id = generate_id()
    pubky_noise_file_ref_id = generate_id()
    paykit_buildfile_id = generate_id()
    pubky_noise_buildfile_id = generate_id()
    paykit_embed_id = generate_id()
    pubky_noise_embed_id = generate_id()
    embed_frameworks_phase_id = generate_id()
    
    # Check if already added
    if 'PaykitMobile.xcframework' in content:
        print("PaykitMobile.xcframework already in project")
        return False
    
    # 1. Add PBXFileReference entries
    file_ref_section = r'(/\* End PBXFileReference section \*/)'
    file_refs = f'''\t\t{paykit_file_ref_id} /* PaykitMobile.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = PaykitMobile.xcframework; sourceTree = "<group>"; }};
\t\t{pubky_noise_file_ref_id} /* PubkyNoise.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = PubkyNoise.xcframework; sourceTree = "<group>"; }};
\\1'''
    content = re.sub(file_ref_section, file_refs, content)
    
    # 2. Add PBXBuildFile entries
    buildfile_section = r'(/\* End PBXBuildFile section \*/)'
    buildfiles = f'''\t\t{paykit_buildfile_id} /* PaykitMobile.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {paykit_file_ref_id} /* PaykitMobile.xcframework */; }};
\t\t{pubky_noise_buildfile_id} /* PubkyNoise.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {pubky_noise_file_ref_id} /* PubkyNoise.xcframework */; }};
\t\t{paykit_embed_id} /* PaykitMobile.xcframework in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {paykit_file_ref_id} /* PaykitMobile.xcframework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};
\t\t{pubky_noise_embed_id} /* PubkyNoise.xcframework in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {pubky_noise_file_ref_id} /* PubkyNoise.xcframework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};
\\1'''
    content = re.sub(buildfile_section, buildfiles, content)
    
    # 3. Add to Frameworks group
    frameworks_group = r'(961058EC2C35798C00E1F1D8 /\* Frameworks \*/ = \{[^}]+children = \()[^)]*(\);)'
    frameworks_group_replacement = f'''\\1
\t\t\t\t{paykit_file_ref_id} /* PaykitMobile.xcframework */,
\t\t\t\t{pubky_noise_file_ref_id} /* PubkyNoise.xcframework */,
\t\t\t\\2'''
    content = re.sub(frameworks_group, frameworks_group_replacement, content, flags=re.DOTALL)
    
    # 4. Add to Frameworks build phase (for Bitkit target)
    frameworks_phase = r'(96FE1F5E2C2DE6AA006D0C8B /\* Frameworks \*/ = \{[^}]+files = \()[^)]*(\);)'
    frameworks_phase_replacement = f'''\\1
\t\t\t\t{paykit_buildfile_id} /* PaykitMobile.xcframework in Frameworks */,
\t\t\t\t{pubky_noise_buildfile_id} /* PubkyNoise.xcframework in Frameworks */,
\t\t\t\\2'''
    content = re.sub(frameworks_phase, frameworks_phase_replacement, content, flags=re.DOTALL)
    
    # 5. Add Embed Frameworks build phase
    # Find the Bitkit target's buildPhases
    bitkit_target = r'(96FE1F602C2DE6AA006D0C8B /\* Bitkit \*/ = \{[^}]+buildPhases = \()[^)]*(\);)'
    embed_phase_add = f'''\\1
\t\t\t\t{embed_frameworks_phase_id} /* Embed Frameworks */,
\t\t\t\\2'''
    content = re.sub(bitkit_target, embed_phase_add, content, flags=re.DOTALL)
    
    # Add the Embed Frameworks phase definition
    copy_files_section = r'(/\* End PBXCopyFilesBuildPhase section \*/)'
    embed_phase_def = f'''\t\t{embed_frameworks_phase_id} /* Embed Frameworks */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\tdstPath = "";
\t\tdstSubfolderSpec = 10;
\t\tfiles = (
\t\t\t{paykit_embed_id} /* PaykitMobile.xcframework in Embed Frameworks */,
\t\t\t{pubky_noise_embed_id} /* PubkyNoise.xcframework in Embed Frameworks */,
\t\t);
\t\tname = "Embed Frameworks";
\t\trunOnlyForDeploymentPostprocessing = 0;
\t}};
\\1'''
    content = re.sub(copy_files_section, embed_phase_def, content)
    
    # 6. Add Framework Search Paths to build settings
    # Find the Bitkit target's build configuration
    framework_search_paths = r'(FRAMEWORK_SEARCH_PATHS = \([^)]*)(\);|\))'
    # This is more complex - we need to find the build configuration for the Bitkit target
    # For now, let's add it to the project-level settings
    
    # Write the modified content
    with open(project_path, 'w') as f:
        f.write(content)
    
    print(f"✅ Added PaykitMobile.xcframework (ID: {paykit_file_ref_id})")
    print(f"✅ Added PubkyNoise.xcframework (ID: {pubky_noise_file_ref_id})")
    print(f"✅ Added to Frameworks build phase")
    print(f"✅ Added Embed Frameworks build phase")
    print("\n⚠️  Note: You may need to manually add Framework Search Paths in Xcode:")
    print("   Build Settings → Framework Search Paths → Add:")
    print("   $(PROJECT_DIR)/Bitkit/PaykitIntegration/Frameworks")
    
    return True

if __name__ == '__main__':
    project_path = 'Bitkit.xcodeproj/project.pbxproj'
    if add_xcframework_to_project(project_path):
        print("\n✅ Successfully added XCFrameworks to Xcode project!")
    else:
        print("\n⚠️  XCFrameworks may already be in project or error occurred")
        sys.exit(1)

