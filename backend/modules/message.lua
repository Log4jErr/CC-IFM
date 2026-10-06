-- IFM :: modules/message.lua
-- Single source of truth for everything the web page displays.
--
-- Rules:
--   * Lua sources stay pure ASCII (checked by tools/ascii_source.py), so the
--     server never hard-codes a translation and never ships one: a message is a
--     node  { key = "msg.<owner>.<area>.<name>", params = { ... } }  and the
--     browser turns the key into text (frontend/web/ifm-messages.js holds the
--     same keys; ifm-core.js does the lookup).
--   * Logs and the diagnose report stay plain English ASCII text: the CC:T
--     terminal cannot translate anything, so they are not messages.
--
-- Usage from a module that got this module injected as `Message`:
--     return nil, self.Message.msg(self.Message.KEYS.JSONFILE_NOT_FOUND, { label = label })
local Message = {}

Message.KEYS = {
    -- modules/jsonfile.lua
    JSONFILE_NOT_FOUND    = "msg.jsonfile.err.notFound",      -- {label}
    JSONFILE_OPEN_FAILED  = "msg.jsonfile.err.openFailed",    -- {path}
    JSONFILE_PARSE_FAILED = "msg.jsonfile.err.parseFailed",   -- {label}

    -- modules/protocol.lua
    PROTOCOL_REQUEST_FAILED = "msg.protocol.err.requestFailed", -- {error}
    -- shared labels reused inside other messages
    COMMON_ITEM           = "msg.common.item",
    COMMON_FLUID          = "msg.common.fluid",
    COMMON_ITEM_INVENTORY = "msg.common.itemInventory",
    COMMON_FLUID_STORAGE  = "msg.common.fluidStorage",

    -- IFMMaster.lua: web request handlers
    MASTER_ERR_CONTAINER_NOT_FOUND   = "msg.master.err.containerNotFound",   -- {name}
    MASTER_ERR_OUTPUT_ONLY           = "msg.master.err.outputOnly",
    MASTER_ERR_SEND_LIST_EMPTY       = "msg.master.err.sendListEmpty",
    MASTER_ERR_RESOURCE_INFO_MISSING = "msg.master.err.resourceInfoMissing",
    MASTER_ERR_CONTAINER_KIND        = "msg.master.err.containerKindMismatch", -- {name, kind}
    MASTER_ERR_CONTAINER_DEF_MISSING = "msg.master.err.containerDefMissing",
    MASTER_ERR_CONTAINER_UNUSABLE    = "msg.master.err.containerUnusable",
    MASTER_ERR_PICK_RESOURCE         = "msg.master.err.pickResource",
    MASTER_ERR_NO_STORAGE            = "msg.master.err.noStorage",
    MASTER_ERR_DISPATCH_UNAVAILABLE  = "msg.master.err.dispatchUnavailable",
    MASTER_ERR_MANUAL_NO_WORKER      = "msg.master.err.manualNoWorker",
    MASTER_ERR_MANUAL_TIMEOUT        = "msg.master.err.manualTimeout", -- {seconds}
    MASTER_ERR_MOVE_NOTHING          = "msg.master.err.moveNothing",
    MASTER_ERR_VIRTUAL_READONLY      = "msg.master.err.virtualReadonly",
    MASTER_ERR_CONTAINER_KIND_BAD    = "msg.master.err.containerKindInvalid",
    MASTER_ERR_PERIPHERAL_CAPABILITY = "msg.master.err.peripheralCapability", -- {name, kind}
    MASTER_ERR_VIRTUAL_NO_DELETE     = "msg.master.err.virtualNoDelete",
    MASTER_ERR_UNKNOWN_ACTION        = "msg.master.err.unknownAction",        -- {action}

    -- modules/store.lua
    STORE_REF_MACHINE                = "msg.store.ref.machine", -- {name}
    STORE_REF_FILTER                 = "msg.store.ref.filter", -- {name}
    STORE_REF_PROCESS                = "msg.store.ref.process", -- {name}
    STORE_ERR_IN_USE                 = "msg.store.err.inUse", -- {refs[]}
    STORE_ERR_IN_USE_MORE            = "msg.store.err.inUseMore", -- {refs[]}
    STORE_LABEL_INPUT                = "msg.store.label.input",
    STORE_LABEL_OUTPUT               = "msg.store.label.output",
    STORE_LABEL_ITEM_INPUTS          = "msg.store.label.itemInputs",
    STORE_LABEL_FLUID_INPUTS         = "msg.store.label.fluidInputs",
    STORE_LABEL_ITEM_OUTPUTS         = "msg.store.label.itemOutputs",
    STORE_LABEL_FLUID_OUTPUTS        = "msg.store.label.fluidOutputs",
    STORE_LABEL_FLUID_CONTAINER      = "msg.store.label.fluidContainer",
    STORE_LABEL_ITEM_CONTAINER       = "msg.store.label.itemContainer",
    STORE_ERR_UNKNOWN_KIND           = "msg.store.err.unknownKind", -- {kind}
    STORE_ERR_NAME_EMPTY             = "msg.store.err.nameEmpty",
    STORE_ERR_DEF_MISSING            = "msg.store.err.defMissing",
    STORE_ERR_RULE_NOT_TABLE         = "msg.store.err.ruleNotTable", -- {index}
    STORE_ERR_RULE_KIND_UNKNOWN      = "msg.store.err.ruleKindUnknown", -- {index, kind}
    STORE_ERR_RULE_NO_TARGET         = "msg.store.err.ruleNoTarget", -- {index}
    STORE_ERR_FILTER_SELF_REF        = "msg.store.err.filterSelfRef",
    STORE_ERR_FILTER_MISSING         = "msg.store.err.filterMissing", -- {name}
    STORE_ERR_FILTER_CYCLE           = "msg.store.err.filterCycle",
    STORE_ERR_ELEMENT_NOT_TABLE      = "msg.store.err.elementNotTable", -- {label, index}
    STORE_ERR_ELEMENT_NO_RESOURCE    = "msg.store.err.elementNoResource", -- {label, index}
    STORE_ERR_ELEMENT_FILTER_MISSING = "msg.store.err.elementFilterMissing", -- {label, index, filter}
    STORE_ERR_ELEMENT_MAX_AMOUNT     = "msg.store.err.elementMaxAmount", -- {label, index}
    STORE_ERR_ELEMENT_MIN_OVER_MAX   = "msg.store.err.elementMinOverMax", -- {label, index}
    STORE_ERR_ELEMENT_EXPECT         = "msg.store.err.elementExpect", -- {label, index}
    STORE_ERR_ELEMENT_COUNT          = "msg.store.err.elementCount", -- {label, index}
    STORE_ERR_ELEMENT_CONTAINER_INDEX = "msg.store.err.elementContainerIndex", -- {label, index}
    STORE_ERR_ELEMENT_SLOT           = "msg.store.err.elementSlot", -- {label, index}
    STORE_ERR_ELEMENT_PLACEHOLDER    = "msg.store.err.elementPlaceholder", -- {label, index}
    STORE_ERR_ELEMENT_PLACEHOLDER_NAME = "msg.store.err.elementPlaceholderName", -- {label, index}
    STORE_ERR_ELEMENT_PLACEHOLDER_ITEM = "msg.store.err.elementPlaceholderItem", -- {label, index}
    STORE_ERR_ELEMENT_SIGNAL_INDEX   = "msg.store.err.elementSignalIndex", -- {label, index}
    STORE_ERR_ELEMENT_SIDE           = "msg.store.err.elementSide", -- {label, index, side}
    STORE_ERR_ELEMENT_OP             = "msg.store.err.elementOp", -- {label, index}
    STORE_ERR_ELEMENT_SECONDS        = "msg.store.err.elementSeconds", -- {label, index}
    STORE_ERR_ELEMENT_KIND           = "msg.store.err.elementKind", -- {label, index, kind}
    STORE_ERR_PERIPHERAL_NAME_EMPTY  = "msg.store.err.peripheralNameEmpty",
    STORE_ERR_CONTAINER_ROLE         = "msg.store.err.containerRole",
    STORE_ERR_CONTAINER_KIND         = "msg.store.err.containerKind",
    STORE_ERR_CONTAINER_PRIORITY     = "msg.store.err.containerPriority",
    STORE_ERR_PERIPHERAL_ASSIGNED    = "msg.store.err.peripheralAssigned", -- {peripheral, name}
    STORE_ERR_MACHINE_TYPE_REQUIRED  = "msg.store.err.machineTypeRequired",
    STORE_ERR_MACHINE_TYPE_MISSING   = "msg.store.err.machineTypeMissing", -- {type}
    STORE_ERR_CONTAINER_MISSING      = "msg.store.err.containerMissing", -- {label, name, kind}
    STORE_ERR_CONTAINER_ROLE_INTERACTION = "msg.store.err.containerRoleInteraction", -- {label, name}
    STORE_ERR_SIGNAL_NAME_EMPTY      = "msg.store.err.signalNameEmpty",
    STORE_ERR_PARALLEL_MIN           = "msg.store.err.parallelMin",
    STORE_ERR_MAX_MULTIPLIER         = "msg.store.err.maxMultiplier",
    STORE_ERR_PROCESS_EMPTY          = "msg.store.err.processEmpty",
    STORE_ERR_TYPE_CONVERSION_INPUT  = "msg.store.err.typeConversionInput",
    STORE_ERR_TYPE_CONVERSION_OUTPUT = "msg.store.err.typeConversionOutput",
    STORE_ERR_TYPE_CONVERSION_OPS    = "msg.store.err.typeConversionOps",

    -- modules/containers.lua
    CONT_LABEL_SOURCE                    = "msg.containers.label.source",
    CONT_LABEL_TARGET                    = "msg.containers.label.target",
    CONT_ERR_SAME_PERIPHERAL             = "msg.containers.err.samePeripheral", -- {from, to, peripheral}
    CONT_ERR_UNSPECIFIED                 = "msg.containers.err.unspecified",
    CONT_ERR_DEF_MISSING                 = "msg.containers.err.defMissing", -- {name}
    CONT_ERR_DEF_KIND                    = "msg.containers.err.defKind", -- {name, kind}
    CONT_ERR_PERIPHERAL_MISSING          = "msg.containers.err.peripheralMissing", -- {name, peripheral}
    CONT_ERR_SCANNING                    = "msg.containers.err.scanning", -- {name, peripheral}
    CONT_ERR_NO_FLUID_CAPABILITY         = "msg.containers.err.noFluidCapability", -- {peripheral}
    CONT_ERR_NO_ITEM_CAPABILITY          = "msg.containers.err.noItemCapability", -- {peripheral}
    CONT_ERR_SOURCE_UNUSABLE             = "msg.containers.err.sourceUnusable", -- {name}
    CONT_ERR_TARGET_UNUSABLE             = "msg.containers.err.targetUnusable", -- {name}
    CONT_ERR_COUNT                       = "msg.containers.err.count",
    CONT_ERR_SOURCE_NO_SNAPSHOT          = "msg.containers.err.sourceNoSnapshot",
    CONT_ERR_SNAPSHOT_NO_ITEM            = "msg.containers.err.snapshotNoItem",
    CONT_ERR_TARGET_NO_SNAPSHOT          = "msg.containers.err.targetNoSnapshot",
    CONT_ERR_TARGET_FULL                 = "msg.containers.err.targetFull",
    CONT_ERR_TARGET_SLOTS_CLAIMED        = "msg.containers.err.targetSlotsClaimed",
    CONT_ERR_TARGET_NO_SLOT              = "msg.containers.err.targetNoSlot",
    CONT_ERR_SOURCE_ITEM_MISMATCH        = "msg.containers.err.sourceItemMismatch", -- {snapshot, wanted}
    CONT_ERR_SOURCE_EMPTY_SLOT           = "msg.containers.err.sourceEmptySlot",
    CONT_ERR_PERIPHERAL_NAME_INVALID     = "msg.containers.err.peripheralNameInvalid", -- {what}
    CONT_ERR_NO_SNAPSHOT                 = "msg.containers.err.noSnapshot", -- {what}
    CONT_ERR_SLOT_INVALID                = "msg.containers.err.slotInvalid",
    CONT_ERR_SLOT_CLAIMED                = "msg.containers.err.slotClaimed", -- {peripheral, slot}
    CONT_ERR_SLOT_EMPTY                  = "msg.containers.err.slotEmpty", -- {peripheral, slot}
    CONT_ERR_SLOT_ITEM_MISMATCH          = "msg.containers.err.slotItemMismatch", -- {peripheral, slot, found, foundNbt, wanted, wantedNbt}
    CONT_ERR_DIRTY_EXCEEDS               = "msg.containers.err.dirtyExceeds", -- {peripheral, slot, dirty, snapshot}
    CONT_ERR_NOT_ENOUGH_SAFE             = "msg.containers.err.notEnoughSafe", -- {count, peripheral, slot, available, snapshot, dirty}
    CONT_ERR_FLUID_NAME_INVALID          = "msg.containers.err.fluidNameInvalid",
    CONT_ERR_FLUID_NOT_ENOUGH            = "msg.containers.err.fluidNotEnough", -- {count, peripheral, fluid, available}
    CONT_ERR_ITEM_SPEC                   = "msg.containers.err.itemSpec",
    CONT_ERR_ITEM_SPEC_SHORT             = "msg.containers.err.itemSpecShort",
    CONT_ERR_SOURCE_CONTAINER_UNAVAILABLE = "msg.containers.err.sourceContainerUnavailable", -- {name}
    CONT_ERR_TARGET_CONTAINER_UNAVAILABLE = "msg.containers.err.targetContainerUnavailable", -- {name}
    CONT_ERR_ROLE_SOURCE                 = "msg.containers.err.roleSource", -- {name, role, action}
    CONT_ERR_ROLE_TARGET                 = "msg.containers.err.roleTarget", -- {name, role, action}
    CONT_ERR_TARGET_SLOT_INVALID         = "msg.containers.err.targetSlotInvalid",
    CONT_ERR_TARGET_SLOT_CLAIMED         = "msg.containers.err.targetSlotClaimed", -- {peripheral, slot}
    CONT_ERR_TARGET_SLOT_BUSY            = "msg.containers.err.targetSlotBusy", -- {peripheral, slot, item}
    CONT_ERR_TARGET_SLOT_REQUIRED        = "msg.containers.err.targetSlotRequired",
    CONT_ERR_CONTAINER_UNAVAILABLE       = "msg.containers.err.containerUnavailable", -- {name}
    CONT_ERR_CONTAINER_NO_SNAPSHOT       = "msg.containers.err.containerNoSnapshot",
    CONT_ERR_NO_ITEM_AVAILABLE           = "msg.containers.err.noItemAvailable", -- {container, item}
    CONT_ERR_ALL_SLOTS_CLAIMED           = "msg.containers.err.allSlotsClaimed", -- {container, dirty, size}
    CONT_ERR_FULL                        = "msg.containers.err.full", -- {container, occupied, item}
    CONT_ERR_SCAN_UNAVAILABLE            = "msg.containers.err.scanUnavailable", -- {container, kind}
    CONT_ERR_SCAN_TWICE                  = "msg.containers.err.scanTwice", -- {container, kind}
    CONT_ERR_SOURCE_NO_SNAPSHOT_FLUID    = "msg.containers.err.sourceNoSnapshotFluid",
    CONT_ERR_NO_FLUID                    = "msg.containers.err.noFluid",
    CONT_ERR_NOT_FLUID_CONTAINER         = "msg.containers.err.notFluidContainer", -- {peripheral}
    CONT_ERR_FLUID_MOVE_FAILED           = "msg.containers.err.fluidMoveFailed",

    -- shared with modules/recipe.lua
    COMMON_UNAVAILABLE                       = "msg.common.unavailable",
    RECIPE_LABEL_ITEM_INPUTS                 = "msg.recipe.label.itemInputs",
    RECIPE_LABEL_FLUID_INPUTS                = "msg.recipe.label.fluidInputs",
    RECIPE_LABEL_ITEM_OUTPUTS                = "msg.recipe.label.itemOutputs",
    RECIPE_LABEL_FLUID_OUTPUTS               = "msg.recipe.label.fluidOutputs",
    RECIPE_ERR_CONTAINER_PROBLEM             = "msg.recipe.err.containerProblem", -- {label, container, reason}
    RECIPE_ERR_SIGNAL_DEF_MISSING            = "msg.recipe.err.signalDefMissing", -- {signal}
    RECIPE_ERR_SIGNAL_RELAY_MISSING          = "msg.recipe.err.signalRelayMissing", -- {signal, peripheral}
    RECIPE_ERR_MACHINE_UNAVAILABLE           = "msg.recipe.err.machineUnavailable", -- {machine}
    RECIPE_ERR_MACHINE_UNAVAILABLE_WHY       = "msg.recipe.err.machineUnavailableWhy", -- {machine, problem}

    -- modules/recipe.lua
    RECIPE_ERR_ABSTRACT_PROCESS              = "msg.recipe.err.abstractProcess",
    RECIPE_ERR_NO_MACHINE                    = "msg.recipe.err.noMachine", -- {type}
    RECIPE_ERR_MACHINES_UNUSABLE             = "msg.recipe.err.machinesUnusable",
    RECIPE_ERR_MACHINES_BUSY                 = "msg.recipe.err.machinesBusy",
    RECIPE_ERR_NO_INPUT_CONTAINER            = "msg.recipe.err.noInputContainer",
    RECIPE_ERR_STORAGE_MISSING               = "msg.recipe.err.storageMissing", -- {item}
    RECIPE_ERR_MACHINE_NOT_USABLE            = "msg.recipe.err.machineNotUsable",
    RECIPE_LABEL_FLUID_INPUTS_FULL           = "msg.recipe.label.fluidInputsFull",
    RECIPE_LABEL_ITEM_INPUTS_FULL            = "msg.recipe.label.itemInputsFull",
    RECIPE_ERR_MACHINE_NO_INPUTS             = "msg.recipe.err.machineNoInputs", -- {machine, label}
    RECIPE_ERR_MACHINE_NO_INPUT_INDEX        = "msg.recipe.err.machineNoInputIndex", -- {machine, index, label}
    RECIPE_ERR_CANNOT_SEND                   = "msg.recipe.err.cannotSend", -- {item, machine}
    RECIPE_ERR_NO_OUTPUT_CONTAINER           = "msg.recipe.err.noOutputContainer", -- {machine}
    RECIPE_ERR_NO_FLUID_STORAGE              = "msg.recipe.err.noFluidStorage",
    RECIPE_ERR_NO_TARGET_SLOT                = "msg.recipe.err.noTargetSlot",
    RECIPE_ERR_NO_UPSTREAM                   = "msg.recipe.err.noUpstream",
    RECIPE_WAIT_UPSTREAM                     = "msg.recipe.wait.upstream",
    RECIPE_WAIT_UPSTREAM_MISSING             = "msg.recipe.wait.upstreamMissing",
    RECIPE_WAIT_MOVE_SETTLE                  = "msg.recipe.wait.moveSettle",
    RECIPE_WAIT_TURTLE                       = "msg.recipe.wait.turtle",
    RECIPE_ERR_MOVE_FAILED                   = "msg.recipe.err.moveFailed",
    RECIPE_ERR_OUTPUT_STUCK                  = "msg.recipe.err.outputStuck", -- {machine, item, reason}
    RECIPE_WAIT_MACHINE_OUTPUT               = "msg.recipe.wait.machineOutput", -- {machine, item}
    RECIPE_ERR_MACHINE_TYPE_DELETED          = "msg.recipe.err.machineTypeDeleted", -- {type}
    RECIPE_ERR_DELIVERY_TARGET_UNAVAILABLE   = "msg.recipe.err.deliveryTargetUnavailable", -- {container}
    RECIPE_ERR_NO_PRODUCER                   = "msg.recipe.err.noProducer", -- {item, remaining}
    RECIPE_WAIT_STOCK                        = "msg.recipe.wait.stock", -- {item}
    RECIPE_ERR_INSTANCE_ARGS                 = "msg.recipe.err.instanceArgs",
    RECIPE_ERR_INSTANCE_MISSING              = "msg.recipe.err.instanceMissing", -- {id}
    RECIPE_ERR_NOT_ENOUGH_MATERIALS          = "msg.recipe.err.notEnoughMaterials",
    RECIPE_ERR_NO_PRODUCER_PROCESS           = "msg.recipe.err.noProducerProcess",
    RECIPE_ERR_PROCESS_MISSING               = "msg.recipe.err.processMissing", -- {name}
    RECIPE_ERR_CONVERSION_SHAPE              = "msg.recipe.err.conversionShape",
    RECIPE_ERR_CONVERSION_MISMATCH           = "msg.recipe.err.conversionMismatch", -- {filter, item}
    RECIPE_ERR_CONVERSION_SCANNING           = "msg.recipe.err.conversionScanning", -- {item}
}

function Message.msg(key, params)
    if type(key) ~= "string" or key == "" then
        error("message key must be a non-empty string", 2)
    end
    if params == nil then
        return { key = key }
    end
    return { key = key, params = params }
end

function Message.isMessage(value)
    return type(value) == "table" and type(value.key) == "string"
end

-- Keep a message node as it is and stringify anything else. Container/machine
-- helpers raise Lua errors (nodes) that travel through pcall into the `reason`
-- fields of recipe/IFMMaster, while CC:T and Lua raise plain technical strings:
-- this helper lets both kinds flow through the same plumbing.
function Message.reason(value)
    if type(value) == "table" and type(value.key) == "string" then
        return value
    end
    return tostring(value)
end

-- Server-side description for logs and assertions: never a raw table dump.
function Message.describe(value)
    if type(value) ~= "table" then
        return tostring(value)
    end
    local parts = {}
    for name, item in pairs(value.params or {}) do
        parts[#parts + 1] = tostring(name) .. "=" .. tostring(item)
    end
    table.sort(parts)
    if #parts == 0 then
        return tostring(value.key)
    end
    return tostring(value.key) .. "(" .. table.concat(parts, ",") .. ")"
end

return Message