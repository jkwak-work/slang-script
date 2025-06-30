# Slang Project Memory

*This file accumulates my understanding of the Slang shader compiler project to help with future conversations.*

## Project Overview
Slang is a shader language compiler that extends HLSL with modern language features. It compiles to multiple target languages (HLSL, GLSL, Metal, SPIRV, etc.) and provides a runtime binding system.

## Codebase Architecture Understanding

**Core Structure:**
- `source/slang/` - Main compiler (parsing, type system, IR generation, reflection API)
- `source/compiler-core/` - Shared compiler utilities
- `source/core/` - Basic data structures and utilities
- `external/slang-rhi/src/` - NEW RHI backend implementations (currently active)
- `tools/gfx/` - LEGACY backend implementations (being phased out)
- `tests/` - Comprehensive test suite organized by features/targets

**Key Systems I've Learned:**
1. **Type Layout System** - Critical for resource binding, very complex (5000+ lines in slang-type-layout.cpp)
2. **Target-Specific Backends** - Each graphics API has different resource binding models
3. **Reflection API** - Runtime introspection of shader parameters and layouts
4. **Shader Object System** - Runtime binding and parameter management

## Build System Knowledge
- Uses CMake with presets: `cmake --preset default --fresh` for configuration
- macOS builds: `cmake --build --preset release` or debug
- Test runner: `slang-test` (run from repository root)
- Two parallel RHI systems exist (legacy tools/gfx and new external/slang-rhi)

## Investigation Patterns That Work Well

**For Layout/Binding Issues:**
- Start with `source/slang/slang-type-layout.cpp` - massive file containing core layout logic
- Look for `*LayoutRulesFamilyImpl` classes for target-specific behavior
- Compare `typeLayout->getSize()` vs `typeLayout->getSize(CATEGORY)` for size mismatches

**For Target-Specific Issues:**
- Check `external/slang-rhi/src/{target}/` for new implementations
- Each target has `{target}-shader-object-layout.*` and `{target}-shader-object.*`
- Use `grep_search` to find method implementations across targets

**For Test Investigation:**
- Tests are organized by feature/target in `tests/` subdirectories
- `slang-test` can run specific test filters
- Always run from repository root directory

## Key Technical Insights

**Resource Binding Models Vary by Target:**
- Metal: Argument buffers with Tier 1/2 distinction
- Vulkan: Descriptor sets with layout bindings
- D3D12: Root signatures and descriptor heaps
- Each needs different layout calculations

**Parameter Types Have Universal Distinction:**
- `ConstantBuffer<T>` vs `ParameterBlock<T>` treated differently across all targets
- Layout rules selected via `getConstantBufferRules()` vs `getParameterBlockRules()`
- Function `getParameterBufferElementTypeLayoutRules()` handles this selection

**Size Calculation is Multi-Layered:**
- Slang calculates type layouts including all resources
- RHI backends need to separate uniform data from resource bindings
- Legalization passes can change what gets included in uniform buffers
- Common source of size mismatch bugs

## File Navigation Shortcuts

**For Any Layout Issue:** `source/slang/slang-type-layout.cpp` (huge file, use search)
**For Reflection Issues:** `source/slang/slang-reflection-api.cpp`
**For Parameter Binding:** `source/slang/slang-parameter-binding.cpp`
**For Target Backends:** `external/slang-rhi/src/{metal|vulkan|d3d12}/`
**For Build Issues:** `CMakeLists.txt`, `CMakePresets.json`
**For Testing:** `tools/slang-test/`, `tests/`

## Effective Search Patterns
- `grep -r "ShaderParameterKind::" .` - for resource type handling
- `find . -name "*layout*" -path "*/{target}/*"` - target-specific layout files
- `grep -r "getSize\|getTotalOrdinaryDataSize"` - size calculation issues
- Look for `*LayoutRulesImpl` classes for layout rule implementations

## Common Debugging Approaches
1. **Reproduce with minimal test case** - strip down to essentials
2. **Compare across targets** - reveals target-specific vs universal issues  
3. **Check both old and new RHI** - two systems may behave differently
4. **Trace data flow** - Slang AST → Type Layout → RHI Layout → Runtime
5. **Use reflection API** - query layouts programmatically for investigation

## Build System Gotchas
- `external/slang-rhi` is a submodule that can get out of sync
- Need to use CMake presets for proper configuration
- Some tests may require specific build configurations
- Legacy vs new RHI systems can cause confusion

## Project Patterns I've Observed
- Heavy use of RefPtr for memory management
- Extensive reflection/introspection capabilities
- Target abstraction through layout rule families
- Template-heavy C++ with lots of inheritance hierarchies
- Comprehensive test coverage across multiple graphics APIs

---
*Last updated: January 2025 - Metal RHI investigation* 