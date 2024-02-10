if(APPLE)
  include(FindXCTest)
  add_library(XCTest SHARED IMPORTED)

  # Determine the .../<Platform>.platform/Developer directory prefix where XCTest can be found.
  # TODO: the directories derived from this should probably have a CMakeCache entry.
  set(platform_developer "")
  foreach(d ${CMAKE_Swift_IMPLICIT_INCLUDE_DIRECTORIES})
    if(${d} MATCHES "^(.*[.]platform/Developer)/SDKs/.*")
      string(REGEX REPLACE "^(.*[.]platform/Developer)/SDKs/.*" "\\1" platform_developer ${d})
      break()
    endif()
  endforeach()
  if(${platform_developer} STREQUAL "")
    message(FATAL_ERROR "failed to find platform developer directory in ${CMAKE_Swift_IMPLICIT_INCLUDE_DIRECTORIES}")
  endif()

  target_include_directories(XCTest INTERFACE ${platform_developer}/usr/lib/)
  set_target_properties(XCTest PROPERTIES
    IMPORTED_LOCATION ${platform_developer}/usr/lib/libXCTestSwiftSupport.dylib)
elseif(${CMAKE_HOST_SYSTEM_NAME} STREQUAL "Windows")
  add_library(XCTest SHARED IMPORTED)

  # let SDKROOT = environment["SDKROOT"], let sdkroot = try? AbsolutePath(validating: SDKROOT)
  cmake_path(CONVERT $ENV{SDKROOT} TO_CMAKE_PATH_LIST sdkroot NORMALIZE)
  if(${sdkroot} MATCHES ".*/$") # CMake is nutty about trailing slashes; strip any that are there.
    cmake_path(GET sdkroot PARENT_PATH sdkroot)
  endif()

  # compnerd TEMPORARY; read from SDKSettings.plist
  set(runtime -libc MD)

  # let platform = sdkroot.parentDirectory.parentDirectory.parentDirectory
  cmake_path(GET sdkroot PARENT_PATH platform)
  cmake_path(GET platform PARENT_PATH platform)
  cmake_path(GET platform PARENT_PATH platform)

  # @compnerd TEMPORARY; read from the platform info.plist
  set(xctestVersion development)
  # @compnerd TEMPORARY, derive from CMAKE_SYSTEM_PROCESSOR
  set(archName aarch64)
  # compnerd TEMPORARY, derive from CMAKE_SYSTEM_PROCESSOR
  set(archBin bin64a)

  # let installation: AbsolutePath =
  #     platform.appending("Developer")
  #         .appending("Library")
  #         .appending("XCTest-\(info.defaults.xctestVersion)")
  cmake_path(APPEND platform Developer Library XCTest-${xctestVersion} OUTPUT_VARIABLE installation)

  # "-I",
  # AbsolutePath(validating: "usr/lib/swift/windows", relativeTo: installation).pathString,
  target_include_directories(XCTest INTERFACE
    "${installation}/usr/lib/swift/windows")

  # Migration Path
  #
  # Older Swift (<=5.7) installations placed the XCTest Swift module into the architecture specified
  # directory.  This was in order to match the SDK setup.  However, the toolchain finally gained the
  # ability to consult the architecture independent directory for Swift modules, allowing the merged
  # swiftmodules.  XCTest followed suit.
  #
  # "-I",
  # AbsolutePath(
  #     validating: "usr/lib/swift/windows/\(triple.archName)",
  #     relativeTo: installation
  # ).pathString,
  # "-L",
  # AbsolutePath(validating: "usr/lib/swift/windows/\(triple.archName)", relativeTo: installation)
  #     .pathString,
  target_include_directories(XCTest INTERFACE
    "${installation}/usr/lib/swift/windows/${archName}"
  )
  target_link_directories(XCTest INTERFACE
    "${installation}/usr/lib/swift/windows/${archName}"
  )

  set_target_properties(XCTest PROPERTIES
    # There's no analogy for this in the Swift code but CMake insists on it.
    IMPORTED_IMPLIB "${installation}/usr/lib/swift/windows/${archName}/XCTest.lib"

    # This doesn't seem to have any effect on its own, but it needs to be in the the PATH in order
    # to run the test executable.
    IMPORTED_LOCATION "${installation}/usr/${archBin}/XCTest.dll"
  )

  # Migration Path
  #
  # In order to support multiple parallel installations of an SDK, we need to ensure that we can
  # have all the architecture variant libraries available.  Prior to this getting enabled (~5.7), we
  # always had a singular installed SDK.  Prefer the new variant which has an architecture
  # subdirectory in `bin` if available.
  #
  # let implib = try AbsolutePath(
  #     validating: "usr/lib/swift/windows/XCTest.lib",
  #     relativeTo: installation
  # )
  set(implib "${installation}/usr/lib/swift/windows/XCTest.lib")
  # if localFileSystem.exists(implib) {
  #   xctest.append(contentsOf: ["-L", implib.parentDirectory.pathString])
  # }
  if(EXISTS ${implib})
    cmake_path(GET implib PARENT_PATH p)
    target_link_directories(XCTest INTERFACE ${p})
  endif()

  # @compnerd Which one(s)  of these two do I really need?
  target_compile_options(XCTest INTERFACE -sdk ${sdkroot} ${runtime})
  target_link_options(XCTest INTERFACE -sdk ${sdkroot} ${runtime})

else()
  # I'm not sure this has any effect
  find_package(XCTest CONFIG QUIET)
endif()

# add_swift_xctest(
#   <NAME>
#   <SWIFT_SOURCE> ...
#   DEPENDENCIES <Target> ...
# )
#
# Creates a CTest test target named <NAME> that runs the tests in the given
# Swift source files.
function(add_swift_xctest test_target testee)

  cmake_parse_arguments(ARG "" "" "DEPENDENCIES" ${ARGN})
  set(sources ${ARG_UNPARSED_ARGUMENTS})
  set(dependencies ${ARG_DEPENDENCIES})

  if(APPLE)

    message("sources= ${sources}")
    xctest_add_bundle(${test_target} ${testee} ${sources})
    target_link_libraries(${test_target} PRIVATE XCTest ${dependencies})
    xctest_add_test(XCTest.${test_target} ${test_target})

  else()

    find_package(XCTest CONFIG QUIET)

    set(test_main ${PROJECT_BINARY_DIR}/${test_target}-test_main/main.swift)
    add_custom_command(
      OUTPUT ${test_main}
      COMMAND generate-xctest-main -o ${test_main} ${sources}
      DEPENDS ${sources} generate-xctest-main
      COMMENT "Generate runner for test target ${test_target}")

    add_executable(${test_target} ${test_main} ${sources})

    target_link_libraries(${test_target} PRIVATE ${testee} XCTest ${dependencies})

    add_test(NAME ${test_target}
      COMMAND ${test_target})

    # Attempt to make sure ctest can find the XCTest DLL.
    if(${CMAKE_HOST_SYSTEM_NAME} STREQUAL "Windows")
      get_target_property(xctest_dll_path XCTest IMPORTED_LOCATION)
      message(XCTest DLL: ${xctest_dll_path})
      cmake_path(GET xctest_dll_path PARENT_PATH xctest_dll_directory)
      cmake_path(NATIVE_PATH xctest_dll_directory xctest_dll_directory)
      set_tests_properties(${test_target} PROPERTIES ENVIRONMENT "${xctest_dll_directory};PATH=$ENV{PATH}" )
    endif()

  endif()

endfunction()
