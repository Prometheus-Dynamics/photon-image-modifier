// Based on https://github.com/rmsalinas/aruco/blob/master/trunk/src/arucofidmarkers.cpp

import type { Dictionary } from '@/dictionary.js';

/*
	Extracts a stream of bits from marker data in various formats
*/
function markerBitstream(
	nBits: number,
	data: number | number[] | bigint | string,
): Generator<number> {
	if (typeof data == 'string' || (typeof data == 'number' && nBits > 32)) {
		if (nBits > 32) {
			data = BigInt(data);
		} else {
			data = Number(data);
		}
	}

	if (Array.isArray(data)) {
		return (function* () {
			for (let byte of data) {
				for (let bit = 0; bit < 8; bit++) {
					yield (byte >> (7 - bit)) & 1;
				}
			}
		})();
	}

	if (typeof data == 'number') {
		return (function* () {
			for (let bit = 0; bit < nBits; bit++) {
				yield (data >> (nBits - 1 - bit)) & 1;
			}
		})();
	} else if (typeof data == 'bigint') {
		return (function* () {
			for (let bit = 0; bit < nBits; bit++) {
				yield Number((data >> BigInt(nBits - 1 - bit)) & 1n);
			}
		})();
	} else {
		throw new TypeError('Unrecognized marker codeList type');
	}
}

/**
 * Generate a marker as a NxN matrix of 0s and 1s.
 * Optionally pass a custom dictionary, or leave empty to use the classic ArUco dictionary where N is 5
 * */
export function arucoMarkerMatrix(id: number, dictionary?: Dictionary) {
	const maxTag = dictionary ? dictionary.codeList.length - 1 : 1023;
	if (id < 0 || id > maxTag) {
		throw new RangeError(`Marker ID must be in the range [0..${maxTag}]`);
	}

	let marker: number[][];

	if (dictionary === undefined) {
		// Clasic ArUco dictionary
		const ids = [16, 23, 9, 14];

		marker = Array(5)
			.fill(undefined)
			.map((_) => Array(5).fill(0)); // Zero initialized 2d array

		for (let y = 0; y < 5; y++) {
			const index = (id >> (2 * (4 - y))) & 3;
			const val = ids[index];
			for (let x = 0; x < 5; x++) {
				marker[x][y] = (val >> (4 - x)) & 1;
			}
		}
	} else {
		// Custom dictionary
		const size = Math.ceil(Math.sqrt(dictionary.nBits));
		const data = markerBitstream(dictionary.nBits, dictionary.codeList[id]);

		marker = Array(size)
			.fill(undefined)
			.map((_) => Array(size).fill(0)); // Zero initialized 2d array

		for (let y = 0; y < size; y++) {
			for (let x = 0; x < size; x++) {
				marker[x][y] = data.next().value;
			}
		}
	}

	return marker;
}

/**
 * Create an SVG image of the marker, as a string.
 * Optionally pass a size (in any SVG-compatible units) or leave it out to size it on your own.
 * Optionally pass a custom dictionary, or leave empty to use the classic ArUco dictionary
 */
export function arucoToSVGString(
	id: number,
	size?: number | string,
	dictionary?: Dictionary,
) {
	const marker = arucoMarkerMatrix(id, dictionary);
	const marker_size = marker.length + 2;

	if (size) {
		size = `height="${size}" width="${size}"`;
	} else {
		size = '';
	}

	let image =
		`<svg ${size} viewBox="0 0 ${marker_size} ${marker_size}" version="1.1" xmlns="http://www.w3.org/2000/svg">\n` +
		`  <rect x="0" y="0" width="${marker_size}" height="${marker_size}" fill="black"/>\n`;

	for (let y = 0; y < marker.length; y++) {
		for (let x = 0; x < marker.length; x++) {
			if (marker[x][y] === 1) {
				image +=
					`  <rect x="${x + 1}" y="${y + 1
					}" width="1" height="1" fill="white" ` +
					// Slight stroke to get around aliasing issues with adjacent rectangles
					'stroke="white" stroke-width="0.01" />\n';
			}
		}
	}

	image += '</svg>';

	return image;
}
