# SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause

#[=======================================================================[.rst:
FindBpfObject
--------

Find BpfObject

This module finds if all the dependencies for eBPF Compile-Once-Run-Everywhere
programs are available and where all the components are located.

The caller may set the following variables to disable automatic
search/processing for the associated component:

  ``BPFOBJECT_BPFTOOL_EXE``
    Path to ``bpftool`` binary

  ``BPFOBJECT_CLANG_EXE``
    Path to ``clang`` binary

  ``LIBBPF_INCLUDE_DIRS``
    Path to ``libbpf`` development headers

  ``LIBBPF_LIBRARIES``
    Path to `libbpf` library

  ``BPFOBJECT_VMLINUX_H``
    Path to ``vmlinux.h`` generated by ``bpftool``. If unset, this module will
    attempt to automatically generate a copy.

This module sets the following result variables:

::

  BpfObject_FOUND             = TRUE if all components are found


This module also provides the ``bpf_object()`` macro. This macro generates a
cmake interface library for the BPF object's generated skeleton as well
as the associated dependencies.

.. code-block:: cmake

  bpf_object(<name> <source>)

Given an abstract ``<name>`` for a BPF object and the associated ``<source>``
file, generates an interface library target, ``<name>_skel``, that may be
linked against by other cmake targets.

Example Usage:

::

  find_package(BpfObject REQUIRED)
  bpf_object(myobject myobject.bpf.c)
  add_executable(myapp myapp.c)
  target_link_libraries(myapp myobject_skel)

#]=======================================================================]

if(NOT BPFOBJECT_BPFTOOL_EXE)
  find_program(BPFOBJECT_BPFTOOL_EXE NAMES bpftool DOC "Path to bpftool executable")
endif()

if(NOT BPFOBJECT_CLANG_EXE)
  find_program(BPFOBJECT_CLANG_EXE NAMES clang DOC "Path to clang executable")

  execute_process(COMMAND ${BPFOBJECT_CLANG_EXE} --version
    OUTPUT_VARIABLE CLANG_version_output
    ERROR_VARIABLE CLANG_version_error
    RESULT_VARIABLE CLANG_version_result
    OUTPUT_STRIP_TRAILING_WHITESPACE)

  # Check that clang is new enough
  if(${CLANG_version_result} EQUAL 0)
    if("${CLANG_version_output}" MATCHES "clang version ([^\n]+)\n")
      # Transform X.Y.Z into X;Y;Z which can then be interpreted as a list
      set(CLANG_VERSION "${CMAKE_MATCH_1}")
      string(REPLACE "." ";" CLANG_VERSION_LIST ${CLANG_VERSION})
      list(GET CLANG_VERSION_LIST 0 CLANG_VERSION_MAJOR)

      # Anything older than clang 10 doesn't really work
      string(COMPARE LESS ${CLANG_VERSION_MAJOR} 10 CLANG_VERSION_MAJOR_LT10)
      if(${CLANG_VERSION_MAJOR_LT10})
        message(FATAL_ERROR "clang ${CLANG_VERSION} is too old for BPF CO-RE")
      endif()

      message(STATUS "Found clang version: ${CLANG_VERSION}")
    else()
      message(FATAL_ERROR "Failed to parse clang version string: ${CLANG_version_output}")
    endif()
  else()
    message(FATAL_ERROR "Command \"${BPFOBJECT_CLANG_EXE} --version\" failed with output:\n${CLANG_version_error}")
  endif()
endif()

if(NOT LIBBPF_INCLUDE_DIRS OR NOT LIBBPF_LIBRARIES)
  find_package(LibBpf)
endif()

if(BPFOBJECT_VMLINUX_H)
  get_filename_component(GENERATED_VMLINUX_DIR ${BPFOBJECT_VMLINUX_H} DIRECTORY)
  message(STATUS "${BPFOBJECT_VMLINUX_H}")
elseif(BPFOBJECT_BPFTOOL_EXE)
  # Generate vmlinux.h
  set(GENERATED_VMLINUX_DIR ${CMAKE_CURRENT_BINARY_DIR})
  set(BPFOBJECT_VMLINUX_H ${GENERATED_VMLINUX_DIR}/vmlinux.h)
  execute_process(COMMAND ${BPFOBJECT_BPFTOOL_EXE} btf dump file /sys/kernel/btf/vmlinux format c
    OUTPUT_FILE ${BPFOBJECT_VMLINUX_H}
    ERROR_VARIABLE VMLINUX_error
    RESULT_VARIABLE VMLINUX_result)
  if(${VMLINUX_result} EQUAL 0)
    set(VMLINUX ${BPFOBJECT_VMLINUX_H})
    message(STATUS "VMLINUX_error=${VMLINUX_error}")
    message(STATUS "VMLINUX_result=${VMLINUX_result}")
  else()
    message(FATAL_ERROR "Failed to dump vmlinux.h from BTF: ${VMLINUX_error}")
  endif()
endif()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(BpfObject
  REQUIRED_VARS
    BPFOBJECT_BPFTOOL_EXE
    BPFOBJECT_CLANG_EXE
    LIBBPF_INCLUDE_DIRS
    LIBBPF_LIBRARIES
    GENERATED_VMLINUX_DIR)

# Get clang bpf system includes
execute_process(
  COMMAND bash -c "${BPFOBJECT_CLANG_EXE} -v -E - < /dev/null 2>&1 |
          sed -n '/<...> search starts here:/,/End of search list./{ s| \\(/.*\\)|-idirafter \\1|p }'"
  OUTPUT_VARIABLE CLANG_SYSTEM_INCLUDES_output
  ERROR_VARIABLE CLANG_SYSTEM_INCLUDES_error
  RESULT_VARIABLE CLANG_SYSTEM_INCLUDES_result
  OUTPUT_STRIP_TRAILING_WHITESPACE)
if(${CLANG_SYSTEM_INCLUDES_result} EQUAL 0)
  separate_arguments(CLANG_SYSTEM_INCLUDES UNIX_COMMAND ${CLANG_SYSTEM_INCLUDES_output})
  message(STATUS "BPF system include flags: ${CLANG_SYSTEM_INCLUDES}")
else()
  message(FATAL_ERROR "Failed to determine BPF system includes: ${CLANG_SYSTEM_INCLUDES_error}")
endif()

# Get target arch
execute_process(COMMAND uname -m
  COMMAND sed -e "s/x86_64/x86/" -e "s/aarch64/arm64/" -e "s/ppc64le/powerpc/" -e "s/mips.*/mips/" -e "s/riscv64/riscv/"
  OUTPUT_VARIABLE ARCH_output
  ERROR_VARIABLE ARCH_error
  RESULT_VARIABLE ARCH_result
  OUTPUT_STRIP_TRAILING_WHITESPACE)
if(${ARCH_result} EQUAL 0)
  set(ARCH ${ARCH_output})
  message(STATUS "BPF target arch: ${ARCH}")
else()
  message(FATAL_ERROR "Failed to determine target architecture: ${ARCH_error}")
endif()

# Public macro
macro(bpf_object name input)
  set(BPF_C_FILE ${PROJECT_SOURCE_DIR}/src/${input})
  set(BPF_O_FILE ${CMAKE_CURRENT_BINARY_DIR}/${name}.bpf.o)
  set(BPF_SKEL_FILE ${CMAKE_CURRENT_BINARY_DIR}/${name}.skel.h)
  set(OUTPUT_TARGET ${name}_skel)

  # Build BPF object file
  add_custom_command(OUTPUT ${BPF_O_FILE}
    COMMAND ${BPFOBJECT_CLANG_EXE} -g -O2 -target bpf -D__TARGET_ARCH_${ARCH}
            ${CLANG_SYSTEM_INCLUDES} -I${GENERATED_VMLINUX_DIR} -I${PROJECT_SOURCE_DIR}/include
            -isystem ${LIBBPF_INCLUDE_DIRS} -c ${BPF_C_FILE} -o ${BPF_O_FILE}
    COMMAND_EXPAND_LISTS
    VERBATIM
    DEPENDS ${BPF_C_FILE}
    COMMENT "[clang] Building BPF object: ${name}")

  # Build BPF skeleton header
  add_custom_command(OUTPUT ${BPF_SKEL_FILE}
    COMMAND bash -c "${BPFOBJECT_BPFTOOL_EXE} gen skeleton ${BPF_O_FILE} > ${BPF_SKEL_FILE}"
    VERBATIM
    DEPENDS ${BPF_O_FILE}
    COMMENT "[skel]  Building BPF skeleton: ${name}")

  add_library(${OUTPUT_TARGET} INTERFACE)
  target_sources(${OUTPUT_TARGET} INTERFACE ${BPF_SKEL_FILE})
  target_include_directories(${OUTPUT_TARGET} INTERFACE ${CMAKE_CURRENT_BINARY_DIR})
  target_include_directories(${OUTPUT_TARGET} SYSTEM INTERFACE ${LIBBPF_INCLUDE_DIRS})
  target_link_libraries(${OUTPUT_TARGET} INTERFACE ${LIBBPF_LIBRARIES} -lelf -lz)
endmacro()
