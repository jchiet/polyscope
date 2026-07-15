/*
  A four channel scope scaffold LV2 plugin.

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 2 of the License, or
  (at your option) any later version.
*/

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

#define SCOPE_URI URI_PREFIX "/scope"

#define SCOPE_CHANNELS 4
#define SCOPE_FRAME_SAMPLES 192
#define SCOPE_HISTORY_SAMPLES 768
#define SCOPE_NOTIFY_HEADER_MAX 32
#define SCOPE_NOTIFY_TEXT_MAX (SCOPE_NOTIFY_HEADER_MAX + (SCOPE_CHANNELS * ((SCOPE_FRAME_SAMPLES * 2) + 1)) + 1)
#define SCOPE_NOTIFY_TARGET_HZ 24.0
#define SCOPE_NOTIFY_MIN_FRAMES 64

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

static inline uint8_t
encode_sample(float value)
{
	const float normalized = (clamp_unit(value) * 0.5f) + 0.5f;
	return (uint8_t)lrintf(normalized * 255.0f);
}

static inline char
hex_nibble(uint8_t value)
{
	return value < 10 ? (char)('0' + value) : (char)('A' + (value - 10));
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
	   the falling edge. All modes free-run when no edge is present. */
	const bool falling_mode = (trigger_mode == 2);

	/* Only consider edges where a full frame still fits afterwards, and place
	   the edge at a fixed screen position (pre_trigger from the left) so the
	   trace stays stationary. Keep the most recent qualifying edge. */
	const uint32_t hi = max_start + pre_trigger;
	int found = -1;
	for (uint32_t sample = (pre_trigger == 0 ? 1 : pre_trigger);
	     sample <= hi && sample < plugin->history_count; ++sample) {
		const float previous = history_sample(plugin, channel, sample - 1);
		const float current = history_sample(plugin, channel, sample);
		const bool rising = previous < threshold && current >= threshold;
		const bool falling = previous > threshold && current <= threshold;

		if (falling_mode ? falling : rising) {
			found = (int)sample;
		}
	}

	if (found < 0) {
		return max_start;  /* no edge in range: free-run on the latest window */
	}
	return (uint32_t)found - pre_trigger;
}

static uint32_t
build_notify_packet(PolyScope* plugin)
{
	int written = snprintf(plugin->notify_text,
	                       sizeof(plugin->notify_text),
	                       "PSCP|1|%u",
	                       SCOPE_FRAME_SAMPLES);
	if (written < 0 || (size_t)written >= sizeof(plugin->notify_text)) {
		plugin->notify_text[0] = '\0';
		return 0;
	}

	const uint32_t frame_start = find_frame_start(plugin);
	char* cursor = plugin->notify_text + written;
	for (uint32_t channel = 0; channel < SCOPE_CHANNELS; ++channel) {
		*cursor++ = '|';
		for (uint32_t sample = 0; sample < SCOPE_FRAME_SAMPLES; ++sample) {
			const uint8_t encoded = encode_sample(
				history_sample(plugin, channel, frame_start + sample));
			*cursor++ = hex_nibble((uint8_t)(encoded >> 4));
			*cursor++ = hex_nibble((uint8_t)(encoded & 0x0F));
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
		for (uint32_t sample = 0; sample < SCOPE_HISTORY_SAMPLES; ++sample) {
			plugin->history_data[channel][sample] = 0.0f;
		}
	}

	plugin->frame_write_index = 0;
	plugin->history_count = 0;
	plugin->decimation_counter = 0;
	plugin->frames_since_notify = 0;
	plugin->frame_ready = false;
	plugin->notify_text[0] = '\0';
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

	for (uint32_t channel = 0; channel < SCOPE_CHANNELS; ++channel) {
		last_sample[channel] = plugin->held_sample[channel];
		peak[channel] = freeze ? plugin->held_peak[channel] : 0.0f;
	}

	for (uint32_t frame = 0; frame < sample_count; ++frame) {
		float frame_samples[SCOPE_CHANNELS];

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
			}
		}

		if (!freeze) {
			plugin->decimation_counter += 1;
			if (plugin->decimation_counter >= plugin->decimation) {
				plugin->decimation_counter = 0;

				for (uint32_t channel = 0; channel < SCOPE_CHANNELS; ++channel) {
					plugin->history_data[channel][plugin->frame_write_index] =
						frame_samples[channel];
				}

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
