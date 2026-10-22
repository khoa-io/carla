#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <string>

#include <mcpp.h>

int load_file(void *, const char *filename, const char **contents, size_t *size) {
  const char *source = nullptr;
  if (std::strstr(filename, "native_shader.usf") != nullptr) {
    source = "#include \"constants.ush\"\nfloat4 main() { return float4(NATIVE_VALUE, 0, 0, 1); }\n";
  } else if (std::strstr(filename, "constants.ush") != nullptr) {
    source = "#define NATIVE_VALUE 7\n";
  }
  if (source == nullptr) return 0;
  if (contents != nullptr) *contents = source;
  if (size != nullptr) *size = std::strlen(source) + 1;
  return 1;
}

int main() {
  mcpp_setmalloc(std::malloc, std::realloc, std::free);
  const char *options[] = {"-P", "-V199901L"};
  char *output = nullptr;
  char *errors = nullptr;
  file_loader loader = {load_file, nullptr};
  const int result = mcpp_run(options, 2, "native_shader.usf", &output, &errors, loader);
  std::string compact;
  if (output != nullptr) {
    for (const unsigned char character : std::string(output)) {
      if (!std::isspace(character)) compact += static_cast<char>(character);
    }
  }
  if (result != 0 || compact.find("float4(7,0,0,1)") == std::string::npos) {
    std::fprintf(stderr, "Native shader preprocessing failed (%d): %s\nOutput: %s\n", result,
        errors == nullptr ? "" : errors, output == nullptr ? "" : output);
    return 1;
  }
  std::puts("Native ARM64 MCPP: Unreal file-loader callbacks, includes and shader macro expansion passed");
  return 0;
}
