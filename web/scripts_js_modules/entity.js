export class Entity extends HTMLElement {
    constructor() {
        super();
        this.entity_id = null;
        this.attachShadow({mode: 'open'});
    }

    updateSize() {
        this.size = (GLOBALS.SIZE * GLOBALS.SCALE);
    }
    setLayer(layer) {
        this.layer = layer;
        this.style.zIndex = layer;
    }
    setEntityId(id) {
        this.entity_id = id;
    }
    setViewportXY(x, y) {
        this.setViewportX(x);
        this.setViewportY(y);
    }
    setViewportX(value) {
        this.viewport_x = value;
        this.left = (this.viewport_x * (GLOBALS.SIZE * GLOBALS.SCALE));
    }
    setViewportY(value) {
        this.viewport_y = value;
        this.top = (this.viewport_y * (GLOBALS.SIZE * GLOBALS.SCALE));
    }

    connectedCallback() {
        this.render();
    }

    disconnectedCallback() {}
    adoptedCallback() {}
    attributeChangedCallback() {}

    // TODO: Perhaps put this somewhere more global
    getImageCoords(layer, id, frame) {
        if (frame === null || frame === undefined) {
            frame = 0;
        }
        var current_world_index = _GAME.game_getCurrentWorldIndex();
        if (!GLOBALS.IMAGE_DATA[current_world_index]) {
            return null;
        }
        if (!GLOBALS.IMAGE_DATA[current_world_index][layer]) {
            return null;
        }
        if (!GLOBALS.IMAGE_DATA[current_world_index][layer][id]) {
            return null;
        }
        return GLOBALS.IMAGE_DATA[current_world_index][layer][id][frame];
        // TODO: Real entities (npcs and characters and other "moving" things should have a default image)
    }

    render() {
        this.style.backgroundImage = `url("${GLOBALS.ATLAS_PNG_FILENAME}")`;
        var image_frame_coords = this.getImageCoords(this.layer, this.entity_id, 0);
        if (image_frame_coords !== null && image_frame_coords !== undefined) {
            this.style.backgroundPosition = '-' + image_frame_coords[0] + 'px -' + image_frame_coords[1] + 'px';
        }
        this.shadowRoot.innerHTML = `
            <style>
            :host {
                width: ${this.size}px;
                height: ${this.size}px;
                position: absolute;
                left: ${this.left}px;
                top: ${this.top}px;
                z-index: ${this.layer};
            }
            </style>
            <div></div>
        `;
    }
}
