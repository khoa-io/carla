#include "PxPhysicsAPI.h"

#include <cmath>
#include <iostream>
#include <stdexcept>

int main() {
  using namespace physx;
  PxDefaultAllocator allocator;
  PxDefaultErrorCallback errors;
  PxFoundation *foundation = PxCreateFoundation(PX_FOUNDATION_VERSION, allocator, errors);
  if (!foundation) {
    throw std::runtime_error("PhysX foundation initialization failed");
  }
  PxPhysics *physics = PxCreatePhysics(PX_PHYSICS_VERSION, *foundation, PxTolerancesScale(), false, nullptr);
  if (!physics) {
    foundation->release();
    throw std::runtime_error("PhysX initialization failed");
  }
  if (!PxInitVehicleSDK(*physics)) {
    throw std::runtime_error("PhysX vehicle SDK initialization failed");
  }
  PxDefaultCpuDispatcher *dispatcher = PxDefaultCpuDispatcherCreate(2);
  PxSceneDesc description(physics->getTolerancesScale());
  description.gravity = PxVec3(0.0f, -9.81f, 0.0f);
  description.cpuDispatcher = dispatcher;
  description.filterShader = PxDefaultSimulationFilterShader;
  PxScene *scene = physics->createScene(description);
  PxMaterial *material = physics->createMaterial(0.5f, 0.5f, 0.1f);
  if (!dispatcher || !scene || !material) {
    throw std::runtime_error("PhysX scene initialization failed");
  }
  PxRigidStatic *ground = PxCreatePlane(*physics, PxPlane(0.0f, 1.0f, 0.0f, 0.0f), *material);
  PxRigidDynamic *body = PxCreateDynamic(*physics, PxTransform(PxVec3(0.0f, 5.0f, 0.0f)), PxBoxGeometry(0.5f, 0.5f, 0.5f), *material, 1.0f);
  if (!ground || !body) {
    throw std::runtime_error("PhysX rigid body initialization failed");
  }
  scene->addActor(*ground);
  scene->addActor(*body);
  for (unsigned frame = 0; frame < 240; ++frame) {
    scene->simulate(1.0f / 60.0f);
    if (!scene->fetchResults(true)) {
      throw std::runtime_error("PhysX simulation step failed");
    }
  }
  const float height = body->getGlobalPose().p.y;
  const float speed = body->getLinearVelocity().magnitude();
  body->release();
  ground->release();
  scene->release();
  material->release();
  dispatcher->release();
  PxCloseVehicleSDK();
  physics->release();
  foundation->release();
  if (!std::isfinite(height) || std::abs(height - 0.5f) > 0.1f || !std::isfinite(speed) || speed > 0.1f) {
    throw std::runtime_error("PhysX body did not settle on the ground plane");
  }
  std::cout << "Native ARM64 PhysX: vehicle SDK, 240 fixed physics steps, settled height=" << height << ", speed=" << speed << '\n';
}
