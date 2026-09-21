/**
 * Play back a sine wave through the native ASIO driver of an audio interface,
 * bypassing the Windows audio stack for the lowest possible latency.
 *
 * ASIO support is powered by the JAsioHost bindings and has to be enabled with
 * MultiChannel.useJASIO() before any other Sound library call. After the
 * switch, Sound.list() only shows the ASIO drivers registered in the system.
 * This is a Windows-only feature: on other operating systems (or if no ASIO
 * driver is installed) useJASIO() prints an error message and the sketch
 * continues with the default audio drivers, so the same sketch runs everywhere.
 *
 * Tip: if you don't have a driver from your audio interface manufacturer
 * installed, try the universal ASIO4ALL driver.
 */

import processing.sound.*;

SinOsc sine;
boolean usingASIO;
float frequency = 440;

void setup() {
  size(640, 360);
  background(255);

  // has to be the very first Sound library call of the sketch, before any
  // other Sound library objects are created or devices are selected
  usingASIO = MultiChannel.useJASIO();

  if (usingASIO) {
    // list the ASIO drivers (device ids and channel counts) in the console
    Sound.list();

    // optional: select one particular ASIO driver by name or device id
    // (by default the first driver with a stereo output is used)
    //Sound.outputDevice("ASIO4ALL v2");

    // optional: send sounds only to one particular channel of a
    // multi-channel interface (see the MultiChannelOutput example)
    //MultiChannel.activeChannel(2);
  }
  println("Playing back a sine wave over " + (usingASIO ? "ASIO" : "the default audio driver"));

  // create and start the sine oscillator.
  sine = new SinOsc(this);
  sine.play();

  textSize(32);
}

void draw() {
  // map horizontal mouse position to the oscillator frequency
  frequency = map(mouseX, 0, width, 100.0, 1000.0);
  sine.freq(frequency);

  background(255);
  textAlign(CENTER);
  text(usingASIO ? "ASIO output" : "default output", width/2, height/2);
  text(nf(frequency, 1, 0) + " Hz", width/2, height/2 + 40);
}
