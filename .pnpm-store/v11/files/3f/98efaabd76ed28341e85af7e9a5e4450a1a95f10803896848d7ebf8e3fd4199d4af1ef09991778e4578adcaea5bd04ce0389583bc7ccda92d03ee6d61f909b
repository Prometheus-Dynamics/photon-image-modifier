import { arucoToSVGString as e } from "./aruco-marker.js";
import { APRILTAG_16h5 as t } from "./dictionaries/apriltag_16h5.js";
import { APRILTAG_25h7 as n } from "./dictionaries/apriltag_25h7.js";
import { APRILTAG_25h9 as r } from "./dictionaries/apriltag_25h9.js";
import { APRILTAG_36h9 as i } from "./dictionaries/apriltag_36h9.js";
import { APRILTAG_36h10 as a } from "./dictionaries/apriltag_36h10.js";
import { APRILTAG_36h11 as o } from "./dictionaries/apriltag_36h11.js";
import { ARTAG as s } from "./dictionaries/artag.js";
import { ARTOOLKITPLUS as c } from "./dictionaries/artoolkitplus.js";
import { ARTOOLKITPLUSBCH as l } from "./dictionaries/artoolkitplusbch.js";
import { ARUCO_4X4_1000 as u } from "./dictionaries/aruco_4x4_1000.js";
import { ARUCO_5X5_1000 as d } from "./dictionaries/aruco_5x5_1000.js";
import { ARUCO_6X6_1000 as f } from "./dictionaries/aruco_6x6_1000.js";
import { ARUCO_7X7_1000 as p } from "./dictionaries/aruco_7x7_1000.js";
import { ARUCO_DEFAULT as m } from "./dictionaries/aruco_default.js";
import { ARUCO_MIP_16h3 as h } from "./dictionaries/aruco_mip_16h3.js";
import { ARUCO_MIP_25h7 as g } from "./dictionaries/aruco_mip_25h7.js";
import { CHILITAGS as _ } from "./dictionaries/chilitags.js";
//#region \0rolldown/runtime.js
var v = Object.defineProperty, y = /* @__PURE__ */ ((e, t) => {
	let n = {};
	for (var r in e) v(n, r, {
		get: e[r],
		enumerable: !0
	});
	return t || v(n, Symbol.toStringTag, { value: "Module" }), n;
})({
	APRILTAG_16h5: () => t,
	APRILTAG_25h7: () => n,
	APRILTAG_25h9: () => r,
	APRILTAG_36h10: () => a,
	APRILTAG_36h11: () => o,
	APRILTAG_36h9: () => i,
	ARTAG: () => s,
	ARTOOLKITPLUS: () => c,
	ARTOOLKITPLUSBCH: () => l,
	ARUCO_4X4_1000: () => u,
	ARUCO_5X5_1000: () => d,
	ARUCO_6X6_1000: () => f,
	ARUCO_7X7_1000: () => p,
	ARUCO_DEFAULT: () => m,
	ARUCO_MIP_16h3: () => h,
	ARUCO_MIP_25h7: () => g,
	CHILITAGS: () => _
}), b = class extends HTMLElement {
	constructor() {
		super();
	}
	static get observedAttributes() {
		return [
			"markerid",
			"size",
			"dictionary"
		];
	}
	connectedCallback() {
		this.shadowRoot || (this.attachShadow({ mode: "open" }), this._upgradeProperty("markerId"), this._upgradeProperty("size"), this._upgradeProperty("dictionary"));
		let t = this.dictionary ? y[this.dictionary] : void 0, n = e(this.markerId, this.size ?? void 0, t);
		this.shadowRoot.innerHTML = n;
	}
	_upgradeProperty(e) {
		if (this.hasOwnProperty(e)) {
			let t = this[e];
			delete this[e], this[e] = t;
		}
	}
	attributeChangedCallback() {
		this.connectedCallback();
	}
	get markerId() {
		let e = parseInt(this.getAttribute("markerid") ?? "", 10);
		if (Number.isNaN(e)) throw Error("markerid attribute must be set");
		return e;
	}
	set markerId(e) {
		this.setAttribute("markerid", e.toString());
	}
	get size() {
		return this.getAttribute("size");
	}
	set size(e) {
		e ? this.setAttribute("size", e) : this.removeAttribute("size");
	}
	get dictionary() {
		return this.getAttribute("dictionary");
	}
	set dictionary(e) {
		e ? this.setAttribute("dictionary", e) : this.removeAttribute("dictionary");
	}
};
customElements.define("aruco-marker", b, {});
//#endregion

//# sourceMappingURL=element.js.map