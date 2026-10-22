#include "OSM2ODR.h"
#include "carla/opendrive/OpenDriveParser.h"

#include <iostream>
#include <cstdlib>
#include <stdexcept>
#include <string>

namespace carla {
  [[noreturn]] void throw_exception(const std::exception &error) {
    std::cerr << "Native server exception: " << error.what() << '\n';
    std::abort();
  }
}

int main() {
  const std::string source = R"(<osm version="0.6" generator="carla-native-test">
    <node id="1" lat="52.0" lon="9.0"/>
    <node id="2" lat="52.001" lon="9.0"/>
    <node id="3" lat="52.002" lon="9.001"/>
    <way id="10"><nd ref="1"/><nd ref="2"/><nd ref="3"/>
      <tag k="highway" v="residential"/><tag k="lanes" v="2"/>
      <tag k="maxspeed" v="30"/>
    </way></osm>)";
  osm2odr::OSM2ODRSettings settings;
  settings.proj_string = "+proj=utm +zone=32 +datum=WGS84 +units=m +no_defs";
  const std::string converted = osm2odr::ConvertOSMToOpenDRIVE(source, settings);
  if (converted.find("<OpenDRIVE>") == std::string::npos) {
    throw std::runtime_error("Native OSM conversion did not produce OpenDRIVE");
  }
  const auto map = carla::opendrive::OpenDriveParser::Load(converted);
  if (!map || map->GetRoads().empty()) {
    throw std::runtime_error("Native LibCarla server could not parse converted roads");
  }
  std::cout << "Native server dependencies: OSM conversion and LibCarla OpenDRIVE parsing passed\n";
}
