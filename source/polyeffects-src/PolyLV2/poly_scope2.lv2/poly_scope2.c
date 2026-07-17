/*
  A four channel scope scaffold LV2 plugin.

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 2 of the License, or
  (at your option) any later version.
*/

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lv2/lv2plug.in/ns/ext/atom/forge.h"
#include "lv2/lv2plug.in/ns/ext/atom/atom.h"
#include "lv2/lv2plug.in/ns/ext/urid/urid.h"
#include "lv2/lv2plug.in/ns/lv2core/lv2.h"

#ifndef URI_PREFIX
#define URI_PREFIX "http://polyeffects.com/lv2"
#endif

#define SCOPE_URI URI_PREFIX "/polyscope"

#define SCOPE_CHANNELS 4
#define SCOPE_FRAME_SAMPLES 192
#define SCOPE_HISTORY_SAMPLES 384
/* v3 packet: header (magic|ver|count|4 freqs) + 3 series (point/min/max)
   per channel, each series packed 12-bit base64 (2 samples -> 3 bytes -> 4
   chars, i.e. SCOPE_FRAME_SAMPLES * 2 chars — same size the old hex format
   had). The min/max series give the UI an honest under-sampling envelope;
   the freqs are measured here from the full-rate signal, so the readouts
   cannot alias. */
#define SCOPE_NOTIFY_SERIES 3
#define SCOPE_NOTIFY_HEADER_MAX 96
#define SCOPE_NOTIFY_TEXT_MAX (SCOPE_NOTIFY_HEADER_MAX + (SCOPE_CHANNELS * SCOPE_NOTIFY_SERIES * ((SCOPE_FRAME_SAMPLES * 2) + 1)) + 1)
/* perf7: 48 Hz. The receive path bulk-reads and skips stale frames before
   decode, so overproduction is cheap — and each ingen dispatch bunch now
   carries a fresher frame, roughly doubling the effective display rate. */
#define SCOPE_NOTIFY_TARGET_HZ 48.0
#define SCOPE_NOTIFY_MIN_FRAMES 64
#define SCOPE_FREQ_HYSTERESIS 0.02f

enum PortIndex {
	SCOPE_FREEZE = 0,
	SCOPE_TIMEBASE,
	SCOPE_VOLTS_DIV,
	SCOPE_TRIGGER_SOURCE,
	SCOPE_TRIGGER_MODE,
	SCOPE_TRIGGER_LEVEL,
	SCOPE_VIEW_MODE,
	SCOPE_PERSISTENCE,
	SCOPE_INTENSITY,
	SCOPE_COUPLING_1,
	SCOPE_COUPLING_2,
	SCOPE_COUPLING_3,
	SCOPE_COUPLING_4,
	SCOPE_VISIBLE_1,
	SCOPE_VISIBLE_2,
	SCOPE_VISIBLE_3,
	SCOPE_VISIBLE_4,
	SCOPE_IN_1,
	SCOPE_IN_2,
	SCOPE_IN_3,
	SCOPE_IN_4,
	SCOPE_OUT_1,
	SCOPE_OUT_2,
	SCOPE_OUT_3,
	SCOPE_OUT_4,
	SCOPE_NOTIFY,
	SCOPE_SAMPLE_1,
	SCOPE_SAMPLE_2,
	SCOPE_SAMPLE_3,
	SCOPE_SAMPLE_4,
	SCOPE_PEAK_1,
	SCOPE_PEAK_2,
	SCOPE_PEAK_3,
	SCOPE_PEAK_4,
	SCOPE_HOLDOFF,   /* appended so all existing port indices stay stable */
};

typedef struct {
	LV2_URID_Map* urid_map;
	LV2_Atom_Forge forge;
	double       sample_rate;
	const float* freeze;
	const float* timebase;
	const float* volts_div;
	const float* trigger_source;
	const float* trigger_mode;
	const float* trigger_level;
	const float* view_mode;
	const float* persistence;
	const float* intensity;
	const float* coupling[SCOPE_CHANNELS];
	const float* visible[SCOPE_CHANNELS];
	const float* inputs[SCOPE_CHANNELS];
	float*       outputs[SCOPE_CHANNELS];
	LV2_Atom_Sequence* notify;
	float*       samples[SCOPE_CHANNELS];
	float*       peaks[SCOPE_CHANNELS];
	float        held_sample[SCOPE_CHANNELS];
	float        held_peak[SCOPE_CHANNELS];
	float        history_data[SCOPE_CHANNELS][SCOPE_HISTORY_SAMPLES];
	/* per-bucket min/max recorded at full rate alongside the point samples */
	float        history_min[SCOPE_CHANNELS][SCOPE_HISTORY_SAMPLES];
	float        history_max[SCOPE_CHANNELS][SCOPE_HISTORY_SAMPLES];
	float        bucket_min[SCOPE_CHANNELS];
	float        bucket_max[SCOPE_CHANNELS];
	const float* holdoff;
	/* stateful trigger tracker, used only when holdoff > 0 */
	uint64_t     decim_count;      /* decimated samples written since activate */
	uint64_t     hold_last_edge;
	uint64_t     hold_trig_a;      /* newest accepted trigger (decim stamp) */
	uint64_t     hold_trig_b;      /* previous accepted trigger */
	bool         hold_have_a;
	bool         hold_have_b;
	bool         hold_armed;
	uint32_t     prev_decimation;
	/* per-channel frequency measured from the raw full-rate signal
	   (alias-free, unlike anything derived from the decimated frame) */
	uint64_t     raw_count;
	uint64_t     freq_last_cross[SCOPE_CHANNELS];
	float        freq_period_ema[SCOPE_CHANNELS];
	bool         freq_armed[SCOPE_CHANNELS];
	uint32_t     frame_write_index;
	uint32_t     history_count;
	uint32_t     decimation;
	uint32_t     decimation_counter;
	uint32_t     notify_period_frames;
	uint32_t     frames_since_notify;
	bool         frame_ready;
	char         notify_text[SCOPE_NOTIFY_TEXT_MAX];
} PolyScope;

static const float timebase_ms_divs[] = {0.5f, 1.0f, 2.0f, 5.0f, 10.0f, 20.0f, 50.0f, 100.0f};

static inline float
clamp_unit(float value)
{
	if (value < -1.0f) {
		return -1.0f;
	}
	if (value > 1.0f) {
		return 1.0f;
	}
	return value;
}

static inline uint16_t
encode_sample_12(float value)
{
	const float normalized = (clamp_unit(value) * 0.5f) + 0.5f;
	int32_t q = (int32_t)lrintf(normalized * 4095.0f);
	if (q < 0) { q = 0; }
	if (q > 4095) { q = 4095; }
	return (uint16_t)q;
}

/* Pack two 12-bit samples into 3 bytes. Shared by the notify loop and the
   host golden harness so the tested path IS the shipped path. */
static inline void
pack_pair_12(uint16_t s0, uint16_t s1, uint8_t* out)
{
	out[0] = (uint8_t)(s0 & 0xFF);
	out[1] = (uint8_t)(((s0 >> 8) & 0x0F) | ((s1 & 0x0F) << 4));
	out[2] = (uint8_t)((s1 >> 4) & 0xFF);
}

static const char POLY_B64[] =
	"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* Encode `len` bytes to base64 at `out`; returns pointer past the last char.
   192 samples pack to 288 bytes (divisible by 3), so the hot path never pads;
   the tail cases are kept for safety at other sample counts. */
static char*
poly_b64_encode(char* out, const uint8_t* in, uint32_t len)
{
	uint32_t i = 0;
	while (i + 3 <= len) {
		const uint32_t n = ((uint32_t)in[i] << 16)
		                 | ((uint32_t)in[i + 1] << 8)
		                 |  (uint32_t)in[i + 2];
		*out++ = POLY_B64[(n >> 18) & 0x3F];
		*out++ = POLY_B64[(n >> 12) & 0x3F];
		*out++ = POLY_B64[(n >> 6) & 0x3F];
		*out++ = POLY_B64[n & 0x3F];
		i += 3;
	}
	if (i + 1 == len) {
		const uint32_t n = (uint32_t)in[i] << 16;
		*out++ = POLY_B64[(n >> 18) & 0x3F];
		*out++ = POLY_B64[(n >> 12) & 0x3F];
		*out++ = '=';
		*out++ = '=';
	} else if (i + 2 == len) {
		const uint32_t n = ((uint32_t)in[i] << 16) | ((uint32_t)in[i + 1] << 8);
		*out++ = POLY_B64[(n >> 18) & 0x3F];
		*out++ = POLY_B64[(n >> 12) & 0x3F];
		*out++ = POLY_B64[(n >> 6) & 0x3F];
		*out++ = '=';
	}
	return out;
}

static uint32_t
logical_index_to_ring(const PolyScope* plugin, uint32_t logical_index)
{
	if (plugin->history_count < SCOPE_HISTORY_SAMPLES) {
		return logical_index;
	}

	return (plugin->frame_write_index + logical_index) % SCOPE_HISTORY_SAMPLES;
}

static float
history_sample(const PolyScope* plugin, uint32_t channel, uint32_t logical_index)
{
	return plugin->history_data[channel][logical_index_to_ring(plugin, logical_index)];
}

static uint32_t
find_frame_start(const PolyScope* plugin)
{
	if (plugin->history_count <= SCOPE_FRAME_SAMPLES) {
		return 0;
	}

	const uint32_t max_start = plugin->history_count - SCOPE_FRAME_SAMPLES;
	const uint32_t pre_trigger = SCOPE_FRAME_SAMPLES / 4;

	const int trigger_mode = plugin->trigger_mode ? (int)lroundf(*(plugin->trigger_mode)) : 0;
	const int trigger_source = plugin->trigger_source
		? (int)lroundf(*(plugin->trigger_source)) - 1
		: 0;
	const uint32_t channel = (uint32_t)((trigger_source < 0) ? 0 :
		(trigger_source >= (int)SCOPE_CHANNELS ? (SCOPE_CHANNELS - 1) : trigger_source));
	const float threshold = plugin->trigger_level ? clamp_unit(*(plugin->trigger_level)) : 0.0f;
	/* mode 0 (AUTO) and 1 (RISE) trigger on the rising edge, mode 2 (FALL) on
	   the falling edge, mode 3 (ROLL) free-runs so the newest window scrolls
	   right-to-left (for slow evolving CV). */
	const bool falling_mode = (trigger_mode == 2);
	const bool roll_mode = (trigger_mode == 3);

	if (roll_mode) {
		return max_start;  /* free-run: newest samples, scrolls as history advances */
	}

	/* Holdoff mode: pick the window from the stateful trigger tracker that
	   run() maintains on the live decimated stream. Unlike the scan below,
	   accepted triggers are anchored to the SIGNAL (real time), not to the
	   sliding window, so complex waveforms lock onto the same edge every
	   cycle. holdoff == 0 keeps the legacy scan untouched. */
	const float holdoff_ms = plugin->holdoff ? *(plugin->holdoff) : 0.0f;
	if (holdoff_ms > 0.0f) {
		const uint64_t newest_stamp = plugin->decim_count > 0 ? plugin->decim_count - 1 : 0;
		const uint32_t newest_logical = plugin->history_count - 1;
		const uint64_t candidates[2] = {plugin->hold_trig_a, plugin->hold_trig_b};
		const bool     have[2] = {plugin->hold_have_a, plugin->hold_have_b};
		for (int candidate = 0; candidate < 2; ++candidate) {
			if (!have[candidate]) {
				continue;
			}
			const uint64_t age64 = newest_stamp - candidates[candidate];
			if (age64 > newest_logical) {
				continue;  /* trigger has fallen out of the history buffer */
			}
			const uint32_t age = (uint32_t)age64;
			if (age < SCOPE_FRAME_SAMPLES - pre_trigger) {
				continue;  /* post-trigger part of the window not filled yet */
			}
			const uint32_t trigger_logical = newest_logical - age;
			if (trigger_logical < pre_trigger) {
				continue;
			}
			const uint32_t start = trigger_logical - pre_trigger;
			if (start > max_start) {
				continue;
			}
			return start;
		}
		return max_start;  /* no usable trigger yet: free-run */
	}

	/* Hysteresis: the signal must make a CLEAR excursion to the opposite side of
	   the threshold (by `hyst`) before another trigger can arm. This collapses the
	   several near-threshold crossings a complex waveform makes each cycle into a
	   single, consistent trigger per cycle, so the trace stops hopping between
	   loop points. Keep the most recent qualifying edge, placed at pre_trigger. */
	const float hyst = 0.06f;
	const uint32_t hi = max_start + pre_trigger;
	int found = -1;
	bool armed = false;
	for (uint32_t sample = (pre_trigger == 0 ? 1 : pre_trigger);
	     sample <= hi && sample < plugin->history_count; ++sample) {
		const float current = history_sample(plugin, channel, sample);
		if (falling_mode) {
			if (current > threshold + hyst) {
				armed = true;
			}
			if (armed && current <= threshold) {
				found = (int)sample;
				armed = false;
			}
		} else {
			if (current < threshold - hyst) {
				armed = true;
			}
			if (armed && current >= threshold) {
				found = (int)sample;
				armed = false;
			}
		}
	}

	if (found < 0) {
		return max_start;  /* no edge in range: free-run on the latest window */
	}
	return (uint32_t)found - pre_trigger;
}

static float
current_frequency(const PolyScope* plugin, uint32_t channel)
{
	const float period = plugin->freq_period_ema[channel];
	if (period <= 0.0f) {
		return 0.0f;
	}
	/* decay to 0 when no crossing for 2 s (signal stopped or is DC) */
	if ((plugin->raw_count - plugin->freq_last_cross[channel]) >
	    (uint64_t)(plugin->sample_rate * 2.0)) {
		return 0.0f;
	}
	return (float)plugin->sample_rate / period;
}

static uint32_t
build_notify_packet(PolyScope* plugin)
{
	/* v3: header carries the plugin-measured (alias-free) frequencies, and
	   each channel sends point, bucket-min and bucket-max series, quantized
	   to 12-bit and packed 2-per-3-bytes as base64 (384 chars per series at
	   192 samples). */
	int written = snprintf(plugin->notify_text,
	                       sizeof(plugin->notify_text),
	                       "PSCP|3|%u|%.2f,%.2f,%.2f,%.2f",
	                       SCOPE_FRAME_SAMPLES,
	                       current_frequency(plugin, 0),
	                       current_frequency(plugin, 1),
	                       current_frequency(plugin, 2),
	                       current_frequency(plugin, 3));
	if (written < 0 || (size_t)written >= SCOPE_NOTIFY_HEADER_MAX) {
		plugin->notify_text[0] = '\0';
		return 0;
	}

	const uint32_t frame_start = find_frame_start(plugin);
	char* cursor = plugin->notify_text + written;
	for (uint32_t channel = 0; channel < SCOPE_CHANNELS; ++channel) {
		const float (*stores[SCOPE_NOTIFY_SERIES])[SCOPE_HISTORY_SAMPLES] = {
			plugin->history_data,
			plugin->history_min,
			plugin->history_max,
		};
		for (uint32_t series = 0; series < SCOPE_NOTIFY_SERIES; ++series) {
			*cursor++ = '|';
			uint8_t packed[(SCOPE_FRAME_SAMPLES * 3 + 1) / 2];
			uint32_t byte_index = 0;
			uint32_t sample = 0;
			while (sample + 1 < SCOPE_FRAME_SAMPLES) {
				const uint32_t ring0 =
					logical_index_to_ring(plugin, frame_start + sample);
				const uint32_t ring1 =
					logical_index_to_ring(plugin, frame_start + sample + 1);
				pack_pair_12(encode_sample_12(stores[series][channel][ring0]),
				             encode_sample_12(stores[series][channel][ring1]),
				             packed + byte_index);
				byte_index += 3;
				sample += 2;
			}
			if (sample < SCOPE_FRAME_SAMPLES) {          /* odd tail */
				const uint32_t ring0 =
					logical_index_to_ring(plugin, frame_start + sample);
				const uint16_t s0 = encode_sample_12(stores[series][channel][ring0]);
				packed[byte_index++] = (uint8_t)(s0 & 0xFF);
				packed[byte_index++] = (uint8_t)((s0 >> 8) & 0x0F);
			}
			cursor = poly_b64_encode(cursor, packed, byte_index);
		}
	}

	*cursor = '\0';
	return (uint32_t)(cursor - plugin->notify_text);
}

static void
cleanup(LV2_Handle instance)
{
	free(instance);
}

static void
connect_port(LV2_Handle instance, uint32_t port, void* data)
{
	PolyScope* plugin = (PolyScope*)instance;

	switch (port) {
	case SCOPE_FREEZE:
		plugin->freeze = (const float*)data;
		break;
	case SCOPE_TIMEBASE:
		plugin->timebase = (const float*)data;
		break;
	case SCOPE_VOLTS_DIV:
		plugin->volts_div = (const float*)data;
		break;
	case SCOPE_TRIGGER_SOURCE:
		plugin->trigger_source = (const float*)data;
		break;
	case SCOPE_TRIGGER_MODE:
		plugin->trigger_mode = (const float*)data;
		break;
	case SCOPE_TRIGGER_LEVEL:
		plugin->trigger_level = (const float*)data;
		break;
	case SCOPE_VIEW_MODE:
		plugin->view_mode = (const float*)data;
		break;
	case SCOPE_PERSISTENCE:
		plugin->persistence = (const float*)data;
		break;
	case SCOPE_INTENSITY:
		plugin->intensity = (const float*)data;
		break;
	case SCOPE_COUPLING_1:
	case SCOPE_COUPLING_2:
	case SCOPE_COUPLING_3:
	case SCOPE_COUPLING_4:
		plugin->coupling[port - SCOPE_COUPLING_1] = (const float*)data;
		break;
	case SCOPE_VISIBLE_1:
	case SCOPE_VISIBLE_2:
	case SCOPE_VISIBLE_3:
	case SCOPE_VISIBLE_4:
		plugin->visible[port - SCOPE_VISIBLE_1] = (const float*)data;
		break;
	case SCOPE_IN_1:
	case SCOPE_IN_2:
	case SCOPE_IN_3:
	case SCOPE_IN_4:
		plugin->inputs[port - SCOPE_IN_1] = (const float*)data;
		break;
	case SCOPE_OUT_1:
	case SCOPE_OUT_2:
	case SCOPE_OUT_3:
	case SCOPE_OUT_4:
		plugin->outputs[port - SCOPE_OUT_1] = (float*)data;
		break;
	case SCOPE_NOTIFY:
		plugin->notify = (LV2_Atom_Sequence*)data;
		break;
	case SCOPE_SAMPLE_1:
	case SCOPE_SAMPLE_2:
	case SCOPE_SAMPLE_3:
	case SCOPE_SAMPLE_4:
		plugin->samples[port - SCOPE_SAMPLE_1] = (float*)data;
		break;
	case SCOPE_PEAK_1:
	case SCOPE_PEAK_2:
	case SCOPE_PEAK_3:
	case SCOPE_PEAK_4:
		plugin->peaks[port - SCOPE_PEAK_1] = (float*)data;
		break;
	case SCOPE_HOLDOFF:
		plugin->holdoff = (const float*)data;
		break;
	default:
		break;
	}
}

static LV2_Handle
instantiate(const LV2_Descriptor* descriptor,
            double sample_rate,
            const char* bundle_path,
            const LV2_Feature* const* features)
{
	(void)descriptor;
	(void)bundle_path;

	PolyScope* plugin = (PolyScope*)calloc(1, sizeof(PolyScope));
	if (!plugin) {
		return NULL;
	}

	for (uint32_t index = 0; features && features[index]; ++index) {
		if (!strcmp(features[index]->URI, LV2_URID__map)) {
			plugin->urid_map = (LV2_URID_Map*)features[index]->data;
			break;
		}
	}

	if (!plugin->urid_map) {
		free(plugin);
		return NULL;
	}

	lv2_atom_forge_init(&plugin->forge, plugin->urid_map);
	plugin->sample_rate = sample_rate;
	plugin->notify_period_frames = (uint32_t)(sample_rate / SCOPE_NOTIFY_TARGET_HZ);
	if (plugin->notify_period_frames < SCOPE_NOTIFY_MIN_FRAMES) {
		plugin->notify_period_frames = SCOPE_NOTIFY_MIN_FRAMES;
	}
	plugin->decimation = 1;

	return (LV2_Handle)plugin;
}

static void
activate(LV2_Handle instance)
{
	PolyScope* plugin = (PolyScope*)instance;

	for (uint32_t channel = 0; channel < SCOPE_CHANNELS; ++channel) {
		plugin->held_sample[channel] = 0.0f;
		plugin->held_peak[channel] = 0.0f;
		plugin->bucket_min[channel] = FLT_MAX;
		plugin->bucket_max[channel] = -FLT_MAX;
		plugin->freq_last_cross[channel] = 0;
		plugin->freq_period_ema[channel] = 0.0f;
		plugin->freq_armed[channel] = false;
		for (uint32_t sample = 0; sample < SCOPE_HISTORY_SAMPLES; ++sample) {
			plugin->history_data[channel][sample] = 0.0f;
			plugin->history_min[channel][sample] = 0.0f;
			plugin->history_max[channel][sample] = 0.0f;
		}
	}

	plugin->frame_write_index = 0;
	plugin->history_count = 0;
	plugin->decimation_counter = 0;
	plugin->frames_since_notify = 0;
	plugin->frame_ready = false;
	plugin->notify_text[0] = '\0';
	plugin->decim_count = 0;
	plugin->raw_count = 0;
	plugin->hold_last_edge = 0;
	plugin->hold_trig_a = 0;
	plugin->hold_trig_b = 0;
	plugin->hold_have_a = false;
	plugin->hold_have_b = false;
	plugin->hold_armed = false;
	plugin->prev_decimation = 0;
}

static void
run(LV2_Handle instance, uint32_t sample_count)
{
	PolyScope* plugin = (PolyScope*)instance;
	const bool freeze = plugin->freeze && *(plugin->freeze) > 0.5f;
	float last_sample[SCOPE_CHANNELS];
	float peak[SCOPE_CHANNELS];
	const int timebase_index = plugin->timebase
		? (int)lroundf(*(plugin->timebase))
		: 4;
	const int clamped_timebase_index = timebase_index < 0 ? 0 :
		(timebase_index >= (int)(sizeof(timebase_ms_divs) / sizeof(timebase_ms_divs[0]))
		 ? (int)(sizeof(timebase_ms_divs) / sizeof(timebase_ms_divs[0])) - 1
		 : timebase_index);
	const double target_ms_div = timebase_ms_divs[clamped_timebase_index];
	const double visible_ms = target_ms_div * 10.0;
	const uint32_t target_decimation = (uint32_t)llround(
		(visible_ms * plugin->sample_rate) / (1000.0 * SCOPE_FRAME_SAMPLES));
	plugin->decimation = target_decimation > 0 ? target_decimation : 1;

	/* Timebase change: holdoff distances are measured in decimated samples,
	   so accepted-trigger state from another decimation is meaningless. */
	if (plugin->decimation != plugin->prev_decimation) {
		plugin->prev_decimation = plugin->decimation;
		plugin->hold_have_a = false;
		plugin->hold_have_b = false;
		plugin->hold_armed = false;
		plugin->hold_last_edge = 0;
	}

	const float holdoff_ms = plugin->holdoff ? *(plugin->holdoff) : 0.0f;
	uint64_t holdoff_decim = 0;
	if (holdoff_ms > 0.0f) {
		holdoff_decim = (uint64_t)llround(
			(holdoff_ms * plugin->sample_rate) / (1000.0 * plugin->decimation));
		if (holdoff_decim < 1) {
			holdoff_decim = 1;
		}
	}
	const int hold_mode = plugin->trigger_mode ? (int)lroundf(*(plugin->trigger_mode)) : 0;
	const bool hold_falling = (hold_mode == 2);
	const bool hold_roll = (hold_mode == 3);
	int hold_source = plugin->trigger_source ? (int)lroundf(*(plugin->trigger_source)) - 1 : 0;
	if (hold_source < 0) {
		hold_source = 0;
	}
	if (hold_source >= (int)SCOPE_CHANNELS) {
		hold_source = SCOPE_CHANNELS - 1;
	}
	const float hold_threshold = plugin->trigger_level ? clamp_unit(*(plugin->trigger_level)) : 0.0f;
	const float hold_hyst = 0.06f;

	for (uint32_t channel = 0; channel < SCOPE_CHANNELS; ++channel) {
		last_sample[channel] = plugin->held_sample[channel];
		peak[channel] = freeze ? plugin->held_peak[channel] : 0.0f;
	}

	for (uint32_t frame = 0; frame < sample_count; ++frame) {
		float frame_samples[SCOPE_CHANNELS];
		plugin->raw_count += 1;

		for (uint32_t channel = 0; channel < SCOPE_CHANNELS; ++channel) {
			const float* input = plugin->inputs[channel];
			float* output = plugin->outputs[channel];
			const float value = input ? input[frame] : 0.0f;

			if (output) {
				output[frame] = value;
			}

			frame_samples[channel] = value;
			if (!freeze) {
				last_sample[channel] = value;
				const float abs_value = fabsf(value);
				if (abs_value > peak[channel]) {
					peak[channel] = abs_value;
				}
				/* under-sampling envelope: extremes at full rate */
				if (value < plugin->bucket_min[channel]) {
					plugin->bucket_min[channel] = value;
				}
				if (value > plugin->bucket_max[channel]) {
					plugin->bucket_max[channel] = value;
				}
				/* alias-free frequency: rising-crossing period, hysteresis */
				if (value < -SCOPE_FREQ_HYSTERESIS) {
					plugin->freq_armed[channel] = true;
				} else if (plugin->freq_armed[channel] && value > SCOPE_FREQ_HYSTERESIS) {
					plugin->freq_armed[channel] = false;
					if (plugin->freq_last_cross[channel] > 0) {
						const uint64_t period = plugin->raw_count - plugin->freq_last_cross[channel];
						if (period >= 4) {
							plugin->freq_period_ema[channel] =
								plugin->freq_period_ema[channel] > 0.0f
								? (plugin->freq_period_ema[channel] * 0.75f) + ((float)period * 0.25f)
								: (float)period;
						}
					}
					plugin->freq_last_cross[channel] = plugin->raw_count;
				}
			}
		}

		if (!freeze) {
			plugin->decimation_counter += 1;
			if (plugin->decimation_counter >= plugin->decimation) {
				plugin->decimation_counter = 0;

				for (uint32_t channel = 0; channel < SCOPE_CHANNELS; ++channel) {
					const float bucket_min = plugin->bucket_min[channel];
					const float bucket_max = plugin->bucket_max[channel];
					plugin->history_data[channel][plugin->frame_write_index] =
						frame_samples[channel];
					plugin->history_min[channel][plugin->frame_write_index] =
						bucket_min <= bucket_max ? bucket_min : frame_samples[channel];
					plugin->history_max[channel][plugin->frame_write_index] =
						bucket_min <= bucket_max ? bucket_max : frame_samples[channel];
					plugin->bucket_min[channel] = FLT_MAX;
					plugin->bucket_max[channel] = -FLT_MAX;
				}

				/* Stateful holdoff trigger on the decimated point stream:
				   after an accepted edge, further edges are ignored for
				   holdoff_decim samples, so a complex waveform locks onto
				   the same edge every cycle. Only active when holdoff > 0;
				   the legacy per-notify window scan is untouched otherwise. */
				if (holdoff_decim > 0 && !hold_roll) {
					const float trigger_value = frame_samples[hold_source];
					bool fired = false;
					if (hold_falling) {
						if (trigger_value > hold_threshold + hold_hyst) {
							plugin->hold_armed = true;
						}
						if (plugin->hold_armed && trigger_value <= hold_threshold) {
							plugin->hold_armed = false;
							fired = true;
						}
					} else {
						if (trigger_value < hold_threshold - hold_hyst) {
							plugin->hold_armed = true;
						}
						if (plugin->hold_armed && trigger_value >= hold_threshold) {
							plugin->hold_armed = false;
							fired = true;
						}
					}
					if (fired && (!plugin->hold_have_a ||
					              (plugin->decim_count - plugin->hold_last_edge) >= holdoff_decim)) {
						plugin->hold_trig_b = plugin->hold_trig_a;
						plugin->hold_have_b = plugin->hold_have_a;
						plugin->hold_trig_a = plugin->decim_count;
						plugin->hold_have_a = true;
						plugin->hold_last_edge = plugin->decim_count;
					}
				}
				plugin->decim_count += 1;

				plugin->frame_write_index += 1;
				if (plugin->frame_write_index >= SCOPE_HISTORY_SAMPLES) {
					plugin->frame_write_index = 0;
				}
				if (plugin->history_count < SCOPE_HISTORY_SAMPLES) {
					plugin->history_count += 1;
				}
			}
		}
	}

	for (uint32_t channel = 0; channel < SCOPE_CHANNELS; ++channel) {
		if (!freeze) {
			plugin->held_sample[channel] = last_sample[channel];
			plugin->held_peak[channel] = peak[channel];
		}
		if (plugin->samples[channel]) {
			plugin->samples[channel][0] = plugin->held_sample[channel];
		}
		if (plugin->peaks[channel]) {
			plugin->peaks[channel][0] = plugin->held_peak[channel];
		}
	}

	if (!freeze && plugin->history_count >= SCOPE_FRAME_SAMPLES) {
		plugin->frames_since_notify += sample_count;
		if (plugin->frames_since_notify >= plugin->notify_period_frames) {
			plugin->frame_ready = true;
			plugin->frames_since_notify %= plugin->notify_period_frames;
		}
	}

	if (plugin->notify && plugin->notify->atom.size > 0) {
		LV2_Atom_Forge_Frame sequence_frame;
		lv2_atom_forge_set_buffer(
			&plugin->forge,
			(uint8_t*)plugin->notify,
			plugin->notify->atom.size);
		lv2_atom_forge_sequence_head(&plugin->forge, &sequence_frame, 0);

		if (!freeze && plugin->frame_ready) {
			const uint32_t packet_size = build_notify_packet(plugin);
			if (packet_size > 0) {
				lv2_atom_forge_frame_time(&plugin->forge, 0);
				lv2_atom_forge_string(
					&plugin->forge,
					plugin->notify_text,
					packet_size);
			}
			plugin->frame_ready = false;
		}

		lv2_atom_forge_pop(&plugin->forge, &sequence_frame);
	}
}

static const LV2_Descriptor descriptor = {
	SCOPE_URI,
	instantiate,
	connect_port,
	activate,
	run,
	NULL,
	cleanup,
	NULL,
};

LV2_SYMBOL_EXPORT const LV2_Descriptor*
lv2_descriptor(uint32_t index)
{
	return index == 0 ? &descriptor : NULL;
}
