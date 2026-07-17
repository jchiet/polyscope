/* Host-side golden check: encode a known ramp with the plugin's own
   quantize/pack/base64 helpers and print the base64 series. The Python test
   suite decodes it and asserts a <= 1 LSB round-trip. (Byte-exact equality
   with the Python reference is NOT required: C quantizes in float32, the
   reference in float64, so codes at exact quantization boundaries may
   legitimately differ by one.) */
#include "poly_scope2.c"

int
main(void)
{
	float ramp[SCOPE_FRAME_SAMPLES];
	for (int i = 0; i < SCOPE_FRAME_SAMPLES; ++i) {
		ramp[i] = -1.0f + (2.0f * (float)i) / (float)(SCOPE_FRAME_SAMPLES - 1);
	}

	uint8_t packed[(SCOPE_FRAME_SAMPLES * 3 + 1) / 2];
	uint32_t byte_index = 0;
	for (int i = 0; i + 1 < SCOPE_FRAME_SAMPLES; i += 2) {
		pack_pair_12(encode_sample_12(ramp[i]),
		             encode_sample_12(ramp[i + 1]),
		             packed + byte_index);
		byte_index += 3;
	}

	char out[SCOPE_FRAME_SAMPLES * 2 + 8];
	char* end = poly_b64_encode(out, packed, byte_index);
	*end = '\0';
	printf("%s\n", out);
	return 0;
}
