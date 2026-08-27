#----------------------------------------------------------------
# Generated CMake target import file for configuration "Release".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "BDWgc::gc" for configuration "Release"
set_property(TARGET BDWgc::gc APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(BDWgc::gc PROPERTIES
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libgc.so.1.5.6"
  IMPORTED_SONAME_RELEASE "libgc.so.1"
  )

list(APPEND _cmake_import_check_targets BDWgc::gc )
list(APPEND _cmake_import_check_files_for_BDWgc::gc "${_IMPORT_PREFIX}/lib/libgc.so.1.5.6" )

# Import target "BDWgc::gccpp" for configuration "Release"
set_property(TARGET BDWgc::gccpp APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(BDWgc::gccpp PROPERTIES
  IMPORTED_LINK_DEPENDENT_LIBRARIES_RELEASE "BDWgc::gc"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libgccpp.so.1.5.0"
  IMPORTED_SONAME_RELEASE "libgccpp.so.1"
  )

list(APPEND _cmake_import_check_targets BDWgc::gccpp )
list(APPEND _cmake_import_check_files_for_BDWgc::gccpp "${_IMPORT_PREFIX}/lib/libgccpp.so.1.5.0" )

# Import target "BDWgc::gctba" for configuration "Release"
set_property(TARGET BDWgc::gctba APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(BDWgc::gctba PROPERTIES
  IMPORTED_LINK_DEPENDENT_LIBRARIES_RELEASE "BDWgc::gc"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libgctba.so.1.5.0"
  IMPORTED_SONAME_RELEASE "libgctba.so.1"
  )

list(APPEND _cmake_import_check_targets BDWgc::gctba )
list(APPEND _cmake_import_check_files_for_BDWgc::gctba "${_IMPORT_PREFIX}/lib/libgctba.so.1.5.0" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
