INCLUDE(CMakeForceCompiler)

if(COMMAND cmake_policy)
  # new cmake library link behavior
  cmake_policy(SET CMP0003 NEW)
  # old cmake variable scope behavior
  cmake_policy(SET CMP0011 OLD)
endif(COMMAND cmake_policy)

# this one is important
SET(CMAKE_SYSTEM_NAME patmos)
SET(CMAKE_SYSTEM_PROCESSOR patmos)

SET(CMAKE_MODULE_PATH ${PROJECT_SOURCE_DIR}/cmake/)

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# find clang for cross compiling
find_program(CLANG_EXECUTABLE NAMES patmos-clang clang DOC "Path to the clang front-end.")

if(NOT CLANG_EXECUTABLE)
  message(FATAL_ERROR "clang required for a Patmos build.")
endif()

# read the env var for patmos gold
if(NOT PATMOS_GOLD)
    set(PATMOS_GOLD $ENV{PATMOS_GOLD})
endif()
find_program(PATMOS_GOLD NAMES patmos-gold patmos-ld DOC "Path to the Patmos ELF linker.")

if( PATMOS_GOLD )
  set( PATMOS_GOLD_ENV "/usr/bin/env PATMOS_GOLD=${PATMOS_GOLD} " )
  #set( ENV{PATMOS_GOLD} ${PATMOS_GOLD_BIN} )
endif( PATMOS_GOLD )


CMAKE_FORCE_C_COMPILER(  ${CLANG_EXECUTABLE} GNU)
CMAKE_FORCE_CXX_COMPILER(${CLANG_EXECUTABLE} GNU)

# the clang triple, also used for installation
set(TRIPLE "patmos-unknown-unknown-elf" CACHE STRING "Target triple to compile compiler-rt for.")

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Build type
#
# By default we set the build type to PatRelease. To build without
# optimizations (-O0), set CMAKE_BUILD_TYPE to O0 now (Debug later). This sets
# the -O0 flags and tests that do not support an -O0 build are disabled.
#
# Build with custom flags:
# When CMAKE_BUILD_TYPE is set to None (ie. -DCMAKE_BUILD_TYPE=None), only the
# CMAKE_C(XX)_FLAGS will be used.
#
set(CMAKE_C_FLAGS_O0 "-O0" CACHE STRING "transitional build type for -O0 testing.")
set(CMAKE_C_FLAGS_PATRELEASE "-O2" CACHE STRING "C flags for Patmos release build.")

if (NOT CMAKE_BUILD_TYPE)
  message(STATUS "No build type selected, defaulting to PatRelease")
  set(CMAKE_BUILD_TYPE "PatRelease" CACHE STRING "Build type PatRelease by default" FORCE)
else()
  message(STATUS "Current build type: ${CMAKE_BUILD_TYPE}")
endif()

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# TODO split the test/benchmark-related stuff into a separate file, get this file
# back in sync with patmos-compiler-rt/cmake!
#

# use platin tool-config to configure clang/llvm and pasim
set(CONFIG_PML          "scripts/patmos-config.pml" CACHE STRING "PML target arch description file (default).")
set(CONFIG_PML_LARGERAM "scripts/patmos-config-64m.pml"  CACHE STRING "PML target arch description file (large RAM).")

# support relative and absolute path to a .pml
if (IS_ABSOLUTE ${CONFIG_PML})
  set(CONFIG_PML_FILE ${CONFIG_PML})
else()
  set(CONFIG_PML_FILE "${PROJECT_SOURCE_DIR}/${CONFIG_PML}")
endif()

if (IS_ABSOLUTE ${CONFIG_PML_LARGERAM})
  set(CONFIG_PML_LARGERAM_FILE ${CONFIG_PML_LARGERAM})
else()
  set(CONFIG_PML_LARGERAM_FILE "${PROJECT_SOURCE_DIR}/${CONFIG_PML_LARGERAM}")
endif()

find_program(PLATIN_EXECUTABLE NAMES platin DOC "Path to platin tool.")

if (NOT PLATIN_EXECUTABLE)
  message(WARNING "platin not found, but required to configure tools.")
endif()

# trigger reconfigure if config PML changes
configure_file(${CONFIG_PML_FILE} ${CMAKE_CURRENT_BINARY_DIR}/config.pml.timestamp.txt)
configure_file(${CONFIG_PML_LARGERAM_FILE} ${CMAKE_CURRENT_BINARY_DIR}/config.largeram.pml.timestamp.txt)

function(execute_platin_tool_config TOOL PML RESULTVAR)
  if (EXISTS ${PML})
    execute_process(COMMAND ${PLATIN_EXECUTABLE} tool-config -t ${TOOL} -i ${PML}
		    RESULT_VARIABLE ptc_ret
		    OUTPUT_VARIABLE ptc_result)
    if (NOT "${ptc_ret}" STREQUAL 0)
      MESSAGE(FATAL_ERROR "Call to 'platin tool-config' failed with: ${ptc_ret}")
    endif()

    # any newline in the output (also at the end) would break the subsequent compiler calls
    STRING(REGEX REPLACE "\n" " " ptc_result "${ptc_result}")
    set(${RESULTVAR} ${ptc_result} PARENT_SCOPE)
  else()
    message(FATAL_ERROR "Tool configuration file ${PML} does not exist!")
  endif()
endfunction()

function(get_target_config TGT PML)
  get_target_property(config_prop ${TGT} BUILD_CONFIG)
  if(${config_prop} STREQUAL "largeram")
    set(${PML} ${CONFIG_PML_LARGERAM_FILE} PARENT_SCOPE)
  else()
    set(${PML} ${CONFIG_PML_FILE} PARENT_SCOPE)
  endif()
endfunction()

# set some compiler-related variables;
set(CMAKE_C_COMPILE_OBJECT   "<CMAKE_C_COMPILER>   -target ${TRIPLE} -fno-builtin -emit-llvm <DEFINES> <FLAGS> <INCLUDES> -o <OBJECT> -c <SOURCE>")
set(CMAKE_CXX_COMPILE_OBJECT "<CMAKE_CXX_COMPILER> -target ${TRIPLE} -fno-builtin -emit-llvm <DEFINES> <FLAGS> <INCLUDES> -o <OBJECT> -c <SOURCE>")
set(CMAKE_C_LINK_EXECUTABLE  "${PATMOS_GOLD_ENV}<CMAKE_C_COMPILER> -target ${TRIPLE} -fno-builtin <FLAGS> <CMAKE_C_LINK_FLAGS> <LINK_FLAGS> <OBJECTS> -o <TARGET> -mpreemit-bitcode=<TARGET>.bc -mserialize=<TARGET>.pml -mpatmos-sca-serialize=<TARGET>.scml <LINK_LIBRARIES>")
set(CMAKE_FORCE_C_OUTPUT_EXTENSION ".bc" FORCE)

# RTEMS linking support
if(${TRIPLE} MATCHES "patmos-unknown-rtems")
  message("=====")
  message("RTEMS based build... (EXPERIMENTAL)")
  message("=====")

  # XXX should this be set?
  SET(CMAKE_SYSTEM_NAME rtems)

  if(NOT (IS_DIRECTORY ${RTEMS_LIBPATH}))
    message(FATAL_ERROR "path to RTEMS libs missing")
  endif()

  # custom link command
  set(CMAKE_C_LINK_EXECUTABLE  "<CMAKE_C_COMPILER> -target ${TRIPLE} -fno-builtin <FLAGS> <CMAKE_C_LINK_FLAGS> <LINK_FLAGS> <OBJECTS> -o <TARGET> -mpreemit-bitcode=<TARGET>.bc -mserialize=<TARGET>.pml ${RTEMS_LIBPATH}/start.o ${RTEMS_LIBPATH}/libsyms.ll -l=c <LINK_LIBRARIES> -nostartfiles -Xgold -Map -Xgold map.map -Xgold --script=${RTEMS_LIBPATH}/linkcmds -Xopt -disable-internalize")

  # this does not work for the RTEMS libraries
  #set(CMAKE_FIND_LIBRARY_PREFIXES "")
  #set(CMAKE_FIND_LIBRARY_SUFFIXES .a)
  #find_library(rtemscpu NAMES "rtemscpu" PATHS RTEMS_LIBPATH)
endif()

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# find llvm-config
find_program(LLVM_CONFIG_EXECUTABLE NAMES patmos-llvm-config llvm-config DOC "Path to the llvm-config tool.")

if(NOT LLVM_CONFIG_EXECUTABLE)
  message(FATAL_ERROR "LLVM required for a Patmos build.")
endif()

execute_process(COMMAND ${LLVM_CONFIG_EXECUTABLE} --targets-built
                OUTPUT_VARIABLE LLVM_TARGETS
                OUTPUT_STRIP_TRAILING_WHITESPACE)

if(NOT (${LLVM_TARGETS} MATCHES "Patmos"))
  message(FATAL_ERROR "llvm-config '${LLVM_CONFIG_EXECUTABLE}' does not report 'Patmos' as supported target.")
endif()

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# find ar (use gold ar with LTO plugin (patmos-ar) if available; llvm-ar does not work)
find_program(LLVM_AR_EXECUTABLE NAMES patmos-ar ar DOC "Path to the ar tool.")

if(NOT LLVM_AR_EXECUTABLE)
  message(FATAL_ERROR "llvm-ar required for a Patmos build.")
endif()

set(CMAKE_AR ${LLVM_AR_EXECUTABLE} CACHE FILEPATH "Archiver")

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# find llvm-link
find_program(LLVM_LINK_EXECUTABLE NAMES patmos-llvm-link llvm-link DOC "Path to the llvm-link tool.")

if(NOT LLVM_LINK_EXECUTABLE)
  message(FATAL_ERROR "llvm-link required for a Patmos build.")
endif()

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# find llvm-objdump
find_program(LLVM_OBJDUMP_EXECUTABLE NAMES patmos-llvm-objdump llvm-objdump DOC "Path to the llvm-objdump tool.")

if(NOT LLVM_OBJDUMP_EXECUTABLE)
  message(FATAL_ERROR "llvm-objdump required for a Patmos build.")
endif()

set(CMAKE_OBJDUMP ${LLVM_OBJDUMP_EXECUTABLE} CACHE FILEPATH "Object dumper")

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# find simulator & emulator

set(ENABLE_EMULATOR true CACHE BOOL "Enable testing with Patmos HW emulator.")

find_program(PASIM_EXECUTABLE NAMES pasim DOC "Path to the Patmos simulator pasim.")
set(PASIM_EXTRA_OPTIONS "" CACHE STRING "Additional command-line options passed to the Patmos simulator.")
separate_arguments(PASIM_EXTRA_OPTIONS)

if (ENABLE_EMULATOR)
  find_program(PATMOS_EMULATOR NAMES patmos-emulator DOC "Path to the Chisel-based patmos emulator.")
  set(PATMOS_EMULATOR_OPTIONS "" CACHE STRING "Additional command-line options passed to the Chisel-based patmos emulator.")
  separate_arguments(PATMOS_EMULATOR_OPTIONS)
else()
  message(STATUS "Testing with emulator is disabled.")
endif()

if(PASIM_EXECUTABLE)
  set(ENABLE_TESTING true)
else()
  if(REQUIRES_PASIM)
    message(FATAL_ERROR "pasim required for a Patmos build.")
  else()
    message(WARNING "pasim not found, testing is disabled.")
  endif()
endif()
if(PATMOS_EMULATOR)
  set(ENABLE_TESTING true)
else()
  if(ENABLE_EMULATOR)
    message(WARNING "patmos-emulator not found, testing with emulator is disabled.")
  endif()
endif()

# call this macro when a program should be built for emulator compatability
macro (setup_build_for_emulator exec)
  if(PATMOS_EMULATOR AND ENABLE_EMULATOR)
    # Note: This build-config is currently handled just like the default config,
    #       i.e., it uses the same configuration for compiler and pasim, but
    #       we keep this function around for possible future needs.
    set_target_properties(${exec} PROPERTIES BUILD_CONFIG "hw")
  endif()
endmacro()

# call this macro when a program requires more than 2Mb RAM
macro (setup_build_for_large_ram exec)
  set_target_properties(${exec} PROPERTIES BUILD_CONFIG "largeram")
endmacro()

# call this macro when a program should (also) be tested with the emulator
macro (enable_emulator_test name)
  set(${name}-run-hw-test true)
endmacro()

macro (use_source_flowfacts name)
  # TODO add option to disable trace analysis completely (set TRACE_FACTS to no)
  # Lets still run the trace analysis and compare the results
  set(${name}-trace-facts "compare")
endmacro()

macro (add_pml_input name pml)
  set(${name}-add-pml-input ${pml})
endmacro()

# We need to append the mem/cache configuration to the LINK_FLAGS for the clang link call and cmake does not support
# defaults for target properties. thus we depend on the list of executables we collect in our add_executable() overwrite
# and do this at the very end.
# If an executable should be linked for the emulator, it needs to set the BUILD_CONFIG target property accordingly.
function (setup_all_link_flags)
  get_property(tgt_list GLOBAL PROPERTY tgt_list_prop)
  foreach(TGT ${tgt_list})
    # append any existing link flags (these should NOT contain the hardware flags)
    get_target_property(lf_prop ${TGT} LINK_FLAGS)
    if (lf_prop)
      set(existing_link_flags ${lf_prop})
    else()
      unset(existing_link_flags)
    endif()

    get_target_property(config_prop ${TGT} BUILD_CONFIG)
    if(${config_prop} STREQUAL "largeram")
      set_target_properties(${TGT} PROPERTIES LINK_FLAGS "${existing_link_flags} ${CLANG_PATMOS_CONFIG_LARGERAM}")
    else()
      set_target_properties(${TGT} PROPERTIES LINK_FLAGS "${existing_link_flags} ${CLANG_PATMOS_CONFIG}")
    endif()
  endforeach()
endfunction (setup_all_link_flags)


function (run_sim sim sim_options name prog in out ref)
  # Create symlinks to programs to make job_patmos.sh happy
  string(REGEX REPLACE "^[a-zA-Z0-9]+-(.*)" "\\1" _progname ${name})
  file(TO_CMAKE_PATH ${CMAKE_CURRENT_BINARY_DIR}/${_progname} _namepath)
  file(TO_CMAKE_PATH ${prog} _progpath)
  if (NOT ${_namepath} STREQUAL ${_progpath})
    add_custom_command(OUTPUT ${_namepath} COMMAND ${CMAKE_COMMAND} -E remove -f ${_namepath} COMMAND ${CMAKE_COMMAND} -E create_symlink ${prog} ${_namepath})
    add_custom_target(${name} ALL SOURCES ${_namepath})
  endif()
  set(SIM_ARGS ${sim_options})
  if(NOT ${in} STREQUAL "")
    list(APPEND SIM_ARGS -I ${in})
  endif()
  if(NOT ${out} STREQUAL "")
    list(APPEND SIM_ARGS -O ${out})
    set_property(DIRECTORY APPEND PROPERTY ADDITIONAL_MAKE_CLEAN_FILES ${out})
  endif()
  add_test(NAME ${name} COMMAND ${sim} ${SIM_ARGS} ${prog})
  if(NOT ${ref} STREQUAL "")
    add_test(NAME ${name}-cmp COMMAND ${CMAKE_COMMAND} -E compare_files ${out} ${ref})
    set_tests_properties(${name}-cmp PROPERTIES DEPENDS ${name})
  endif()
endfunction (run_sim)

macro (run_io name prog in out ref)
  if(PASIM_EXECUTABLE)
    get_filename_component(exec ${prog}  NAME_WE)
    get_target_property(config_prop ${exec} BUILD_CONFIG)
    if (${config_prop} STREQUAL "largeram")
      set(sim_config ${PASIM_CONFIG_LARGERAM})
    else()
      set(sim_config ${PASIM_CONFIG})
    endif()
    separate_arguments(sim_config)
    set(SIM_ARGS ${sim_config} ${PASIM_EXTRA_OPTIONS} -V -o ${name}.stats)
    run_sim(${PASIM_EXECUTABLE} "${SIM_ARGS}" "${name}" "${prog}" "${in}" "${out}" "${ref}")
    set_property(DIRECTORY APPEND PROPERTY ADDITIONAL_MAKE_CLEAN_FILES ${name}.stats)
  endif()
  if(${name}-run-hw-test AND PATMOS_EMULATOR AND ENABLE_EMULATOR)
    set(EMU_ARGS ${PATMOS_EMULATOR_OPTIONS})
    separate_arguments(EMU_ARGS)
    run_sim(${PATMOS_EMULATOR} "${EMU_ARGS}" "${name}_hw" ${prog} "${in}" "${out}" "${ref}")
    set_tests_properties(${name}_hw PROPERTIES TIMEOUT 1800)
  endif()
endmacro(run_io)


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# WCET Analysis (via platin)
set(PLATIN_ENABLE_WCET false CACHE BOOL "Enable WCET analysis during tests using Platin.")
set(PLATIN_ENABLE_AIT true CACHE BOOL "Enable aiT-based WCET analysis during tests using Platin.")
set(PLATIN_ENABLE_WCA true CACHE BOOL "Enable platin WCA-based WCET analysis during tests using Platin.")

set(PLATIN_OPTIONS "" CACHE STRING "Additional command-line options passed to the platin tool.")
separate_arguments(PLATIN_OPTIONS)

if (NOT PLATIN_ENABLE_WCET)
  message("WCET analysis with platin manually disabled, will be skipped.")
endif()

# check for the a3 tool.
if (PLATIN_ENABLE_WCET AND PLATIN_ENABLE_AIT)
  message(STATUS "Checking for a3 (${CMAKE_SYSTEM_PROCESSOR}).")
  find_program(A3_EXECUTABLE NAMES a3${CMAKE_SYSTEM_PROCESSOR} a3${CMAKE_SYSTEM_NAME} DOC "Path to the a3 WCET analysis tool.")
  if(A3_EXECUTABLE)
    message(STATUS "Using a3 executable ${A3_EXECUTABLE}.")
  else()
    message(WARNING "a3 not found (${CMAKE_SYSTEM_PROCESSOR}).")
  endif()
endif()

if (A3_EXECUTABLE AND PLATIN_ENABLE_AIT)
  set(PLATIN_WCA_TOOL --a3-command ${A3_EXECUTABLE})
  if (PLATIN_ENABLE_WCA)
    set(PLATIN_WCA_TOOL ${PLATIN_WCA_TOOL} --enable-wca)
  endif()
else()
  set(PLATIN_WCA_TOOL --disable-ait --enable-wca)
  if(PLATIN_ENABLE_WCET AND NOT PLATIN_ENABLE_WCA)
    set(PLATIN_ENABLE_WCET false)
    message(WARNING "No WCET analysis tool available (WCA disabled and a3 not found). Disabling WCET tests.")
  endif()
endif()

if(PLATIN_ENABLE_WCET)
	execute_platin_tool_config("clang"  ${CONFIG_PML_FILE}          CLANG_PATMOS_CONFIG)
	execute_platin_tool_config("clang"  ${CONFIG_PML_LARGERAM_FILE} CLANG_PATMOS_CONFIG_LARGERAM)
	execute_platin_tool_config("pasim"  ${CONFIG_PML_FILE}          PASIM_CONFIG)
	execute_platin_tool_config("pasim"  ${CONFIG_PML_LARGERAM_FILE} PASIM_CONFIG_LARGERAM)
endif()

function (get_target_platin_options name options)
  
  if(${name}-add-pml-input)
    set(add_pml --input ${${name}-add-pml-input})
  endif()

  if(${name}-trace-facts STREQUAL "compare")
    set(trace_opts --recorders "g:bcil" --compare-trace-facts)
  else()
    set(trace_opts --recorders "g:bcil" --use-trace-facts)
  endif()

  set(${options} ${trace_opts} ${add_pml} PARENT_SCOPE)
endfunction()

macro (run_wcet name prog report timeout factor entry)
  if (PLATIN_ENABLE_WCET)
    get_filename_component(exec ${prog}  NAME_WE)
    set_property(DIRECTORY APPEND PROPERTY ADDITIONAL_MAKE_CLEAN_FILES ${report} ${report}.dir)
    get_target_config(${exec} config_pml)
    get_target_platin_options(${name} platin_options)
    add_test(NAME ${name} COMMAND ${PLATIN_EXECUTABLE} wcet ${PLATIN_WCA_TOOL} ${PLATIN_OPTIONS} ${platin_options}
                                                            --analysis-entry ${entry}
                                                            --binary ${prog} --report ${report}
                                                            --input ${config_pml} --input ${prog}.pml
                                                            --check ${factor}
                                                            --objdump-command ${LLVM_OBJDUMP_EXECUTABLE} --pasim-command ${PASIM_EXECUTABLE}
                                                            )
    set_tests_properties(${name} PROPERTIES TIMEOUT ${timeout})
    if (PLATIN_ENABLE_AIT)
      set_tests_properties(${name} PROPERTIES RUN_SERIAL 1)
    endif()
    set_property(DIRECTORY APPEND PROPERTY ADDITIONAL_MAKE_CLEAN_FILES ${report})
  endif()
endmacro(run_wcet)

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# stack cache analysis (and pml export) test

set(ENABLE_STACK_CACHE_ANALYSIS_TESTING true CACHE BOOL "Enable tests for LLVM-based SC analysis")

find_program(ILP_SOLVER NAMES glpsol DOC "Path to GLPK solver.")

if (ENABLE_STACK_CACHE_ANALYSIS_TESTING)
  if (NOT ILP_SOLVER)
    message(WARNING "no ILP solver found, SCA analysis tests disabled.")
  endif()
  if (NOT PLATIN_EXECUTABLE)
    message(WARNING "platin not found, SCA analysis tests disabled.")
  endif()
else()
  message(STATUS "LLVM-based SC analysis tests will be skipped.")
endif()

# bounds file can be empty ("")
macro (set_sca_options target bounds_file)
  if (ENABLE_STACK_CACHE_ANALYSIS_TESTING AND ILP_SOLVER AND "${CMAKE_SYSTEM_NAME}" MATCHES "patmos")
    # enables SCA analysis when building target
    get_target_property(existing_link_flags ${target} LINK_FLAGS)
    if(existing_link_flags)
      message(FATAL_ERROR "set_sca_options about to reset linker flags")
    endif()
    set(props "-mpatmos-enable-stack-cache-analysis -mpatmos-ilp-solver=${PROJECT_SOURCE_DIR}/scripts/solve_ilp_glpk.sh")
    if (NOT "${bounds_file}" STREQUAL "")
      set(props "${props} -mpatmos-stack-cache-analysis-bounds=${bounds_file}")
    endif()
    set_target_properties(${target} PROPERTIES LINK_FLAGS "${props}")
  endif()
endmacro(set_sca_options)

macro (make_ais name prog pml)
  if (ENABLE_STACK_CACHE_ANALYSIS_TESTING AND ILP_SOLVER AND PLATIN_EXECUTABLE AND "${CMAKE_SYSTEM_NAME}" MATCHES "patmos")

    add_test(NAME ${name}-sym COMMAND ${PLATIN_EXECUTABLE} extract-symbols --objdump-command ${LLVM_OBJDUMP_EXECUTABLE} -i ${pml} -o ${prog}.addr.pml ${prog})
    add_test(NAME ${name}-ais COMMAND ${PLATIN_EXECUTABLE} pml2ais --ais ${prog}.ais ${prog}.addr.pml)
    set_tests_properties(${name}-ais PROPERTIES DEPENDS ${name}-sym)

    set_property(DIRECTORY APPEND PROPERTY ADDITIONAL_MAKE_CLEAN_FILES ${prog}.addr.pml ${prog}.ais)
  endif()
endmacro(make_ais)
