#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>

#include <ShaderConductor/ShaderConductor.hpp>

int main(int argc, const char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "Usage: shader-conductor-smoke output.metal\n");
    return 2;
  }
  ShaderConductor::Compiler::SourceDesc source{};
  source.source = "float4 main() : SV_Target0 { return float4(0.25, 0.5, 0.75, 1.0); }";
  source.fileName = "native_shader.hlsl";
  source.entryPoint = "main";
  source.stage = ShaderConductor::ShaderStage::PixelShader;
  ShaderConductor::Compiler::Options options{};
  ShaderConductor::Compiler::TargetDesc target{};
  target.language = ShaderConductor::ShadingLanguage::Msl;
  target.version = "20300";
  target.platform = "macOS";
  auto result = ShaderConductor::Compiler::Compile(source, options, target);
  bool success = !result.hasError && result.target != nullptr && result.isText;
  if (success) {
    const std::string generated(static_cast<const char *>(result.target->Data()), result.target->Size());
    success = generated.find("fragment") != std::string::npos;
    if (success) {
      std::ofstream output(argv[1], std::ios::binary);
      output.write(generated.data(), generated.size());
      success = output.good();
    }
  }
  if (!success && result.errorWarningMsg != nullptr) {
    std::fwrite(result.errorWarningMsg->Data(), 1, result.errorWarningMsg->Size(), stderr);
  }
  ShaderConductor::DestroyBlob(result.target);
  ShaderConductor::DestroyBlob(result.errorWarningMsg);
  if (!success) return 1;
  std::puts("Native ARM64 ShaderConductor/DXC: HLSL to SPIR-V to Metal source passed");
  return 0;
}
