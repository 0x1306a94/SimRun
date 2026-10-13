// motion.h — the Mac's motion sensors as the device's: the accelerometer and gyroscope of an Apple silicon MacBook,
// which app.dylib's motion module serves to CMMotionManager (accelerometer, gyro and device motion). See
// docs/motion.md.
//
// simrund serves SRMO_SERVICE: a sim2host XPC listener registered in simns' global namespace. Requests are xpc
// dictionaries with an "op", and get a reply:
//   "info"  -> {accelerometer: bool, gyro: bool, lid: bool}   the sensors this Mac has (none: a Mac without them)
//   "start" -> {}                                  send this connection samples; the sensors run while any wants them
//   "stop"  -> {}                                  stop sending them (so does closing the connection)
// Any request may instead get {error: string}.
// While started, simrund sends {samples: data}: an array of SRMotionSample, in the order the sensors made them, once
// per gyro sample (SRMO_RATE times a second). They are in the frame of the Mac's base (where the sensors are; the
// app turns them into the device's): x to the right, y towards the hinge, z up out of the keyboard. In iOS's
// units: the accelerometer in g, gravity pulling (flat on a desk it reads (0, 0, -1)); the gyro in radians per second,
// right-handed, raw (with the sensor's bias). t is the sensor's time in seconds of mach_absolute_time, which the app
// shares: CMLogItem's timestamp. The lid angle sensor (SRMO_LID) has x, the angle between the lid and the base in
// radians (0 closed, π/2 upright, π flat open), in whole degrees, 10 times a second (and once on "start").
#pragma once
#include <stdint.h>

#define SRMO_SERVICE "dev.simrun.motion"
#define SRMO_RATE    100

enum { SRMO_ACCELEROMETER = 1, SRMO_GYRO = 2, SRMO_LID = 3 };

typedef struct {
  double t;
  double x, y, z;
  int32_t sensor;   // SRMO_ACCELEROMETER, SRMO_GYRO or SRMO_LID
  int32_t reserved;
} SRMotionSample;
