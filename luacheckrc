std = "lua51"
max_line_length = false
codes = true
ignore = { "212", "213", "311", "431", "432" }
globals = {
  "SlashCmdList", "TsmAnalizeDB", "BINDING_HEADER_TSMA", "BINDING_NAME_TSMA_TOGGLE",
  "BINDING_NAME_TSMA_PANEL", "BINDING_NAME_TSMA_CHART", "SLASH_TSMA1",
  "TsmAnalize_OnCompartmentClick", "TsmAnalize_OnCompartmentEnter", "TsmAnalize_OnCompartmentLeave",
  "TsmAnalizeBlizz", "TsmAnalizeImport",
}
read_globals = {
  "CreateFrame", "UIParent", "Minimap", "GameTooltip", "UIErrorsFrame", "UISpecialFrames", "STANDARD_TEXT_FONT",
  "ChatFontNormal", "SOUNDKIT", "Enum", "TSM_API", "C_Timer", "C_Item", "C_AuctionHouse", "C_Container", "C_AddOns",
  "TooltipDataProcessor", "ChatFrameUtil", "ChatEdit_InsertLink", "HandleModifiedItemClick", "ItemLocation",
  "AuctionHouseFrame", "hooksecurefunc", "tinsert", "strtrim", "wipe", "CopyTable", "time", "date", "GetTime",
  "debugprofilestop", "UnitName", "GetCursorPosition", "IsShiftKeyDown", "PlaySound", "GetBuildInfo", "GetItemInfoInstant",
  "GetItemIcon", "GetItemInfo", "GetAddOnMetadata", "GetContainerNumSlots", "GetContainerItemInfo", "GetInboxNumItems",
  "GetInboxHeaderInfo", "GetInboxInvoiceInfo", "GetInboxText", "AuctionHouseFrameDisplayModeTabTemplate",
  "PanelTemplates_TabResize", "NUM_BAG_SLOTS", "NUM_REAGENTBAG_SLOTS", "ERR_AUCTION_SOLD_S", "ERR_AUCTION_EXPIRED_S",
  "AUCTION_SOLD_MAIL_SUBJECT", "unpack",
}
