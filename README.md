<p align="center">
  <img src="phoevra_logo.png" width="200"/>
</p>

# Phoevra

Phoevra is a Delphi VCL-based software synthesizer that processes Standard MIDI Files and renders them into audio in real time. It parses MIDI event streams at a low level, reconstructs musical notes from Note On/Off events, and converts them into audio using equal-tempered frequency synthesis. The sound engine generates waveform samples through direct mathematical synthesis, applies ADSR envelopes per voice, and mixes all active notes into a single PCM signal. The resulting audio can be played back through the Windows waveOut API or exported as a 16-bit WAV file. The project is focused on demonstrating fundamental digital sound synthesis, MIDI file structure, and real-time audio generation without relying on external audio libraries.
