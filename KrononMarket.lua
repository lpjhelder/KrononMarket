-- KrononMarket — coletor de preços da Casa de Leilões do ecossistema Kronon.
-- Escaneia a AH ao abri-la (throttle de 15 min), guarda o menor buyout unitário
-- por item e expõe esses valores via API para o KrononBags e outros addons.

local KM_PREFIX = "|cff33ff33KrononMarket|r: "
local SCAN_THROTTLE = 15 * 60       -- 15 minutos entre varreduras (account-wide)
local BATCH_SIZE = 250              -- itens processados por lote
local BATCH_DELAY = 0.01           -- pausa entre lotes (segundos)

-- ---------------------------------------------------------------------------
-- i18n leve: tabela EN base + overlay ptBR/esES, com fallback via metatable
-- (chave inexistente devolve a própria chave).
-- ---------------------------------------------------------------------------
local LOCALE = (GetLocale and GetLocale()) or "enUS"
local L = setmetatable({}, { __index = function(_, k) return k end })

local EN = {
  SCAN_START = "Scanning the Auction House…",
  SCAN_DONE = "%d items updated",
  STATUS_NEVER = "never scanned",
  STATUS_AGO = "last scan: %s ago",
  STATUS_ITEMS = "%d items in database",
  STATUS_SCANNING = "scanning in progress…",
  TIP_OPEN_AH = "Open the Auction House to update prices.",
}

local PT = {
  SCAN_START = "Escaneando a Casa de Leilões…",
  SCAN_DONE = "%d itens atualizados",
  STATUS_NEVER = "nunca escaneado",
  STATUS_AGO = "última varredura: há %s",
  STATUS_ITEMS = "%d itens no banco",
  STATUS_SCANNING = "varredura em andamento…",
  TIP_OPEN_AH = "Abra a Casa de Leilões pra atualizar os preços.",
}

local ES = {
  SCAN_START = "Escaneando la Casa de Subastas…",
  SCAN_DONE = "%d objetos actualizados",
  STATUS_NEVER = "nunca escaneado",
  STATUS_AGO = "último escaneo: hace %s",
  STATUS_ITEMS = "%d objetos en la base",
  STATUS_SCANNING = "escaneo en progreso…",
  TIP_OPEN_AH = "Abre la Casa de Subastas para actualizar los precios.",
}

for k, v in pairs(EN) do L[k] = v end
if LOCALE == "ptBR" then
  for k, v in pairs(PT) do L[k] = v end
elseif LOCALE == "esES" or LOCALE == "esMX" then
  for k, v in pairs(ES) do L[k] = v end
end

-- ---------------------------------------------------------------------------
-- Namespace público
-- ---------------------------------------------------------------------------
KrononMarket = KrononMarket or {}

-- ---------------------------------------------------------------------------
-- Estado interno
-- ---------------------------------------------------------------------------
local scanning = false
local replicateStarted = false -- já começamos a processar o 1º REPLICATE_ITEM_LIST_UPDATE? (evita cadeias concorrentes)
local batch = nil          -- mapa itemID -> menor buyout unitário desta varredura
local kmCallbacks = {}

-- ---------------------------------------------------------------------------
-- SavedVariables
-- ---------------------------------------------------------------------------
local function InitDB()
  if type(KrononMarketDB) ~= "table" then KrononMarketDB = {} end
  if type(KrononMarketDB.prices) ~= "table" then KrononMarketDB.prices = {} end
  -- lastScan: number (epoch) ou nil
end

-- ---------------------------------------------------------------------------
-- Util de tempo (formata "Xh Ym" / "Ym" / "Xs")
-- ---------------------------------------------------------------------------
local function FormatDuration(seconds)
  seconds = math.floor(seconds or 0)
  if seconds < 60 then
    return seconds .. "s"
  end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return minutes .. "m"
  end
  local hours = math.floor(minutes / 60)
  local rem = minutes % 60
  if rem > 0 then
    return hours .. "h " .. rem .. "m"
  end
  return hours .. "h"
end

-- ---------------------------------------------------------------------------
-- Callbacks de atualização
-- ---------------------------------------------------------------------------
local function FireCallbacks()
  for i = 1, #kmCallbacks do
    pcall(kmCallbacks[i])
  end
end

-- ---------------------------------------------------------------------------
-- Throttle / pré-condições
-- ---------------------------------------------------------------------------
local function CanScan()
  if scanning then return false end
  if KrononMarketDB == nil then return false end
  if KrononMarketDB.lastScan == nil then return true end
  return (time() - KrononMarketDB.lastScan) > SCAN_THROTTLE
end

-- ---------------------------------------------------------------------------
-- Finalização da varredura: faz MERGE no DB (não apaga itens não vistos)
-- ---------------------------------------------------------------------------
local function EndScan()
  if not scanning then return end

  local now = time()
  local count = 0
  if type(batch) == "table" then
    for itemID, price in pairs(batch) do
      KrononMarketDB.prices[itemID] = { p = price, t = now }
      count = count + 1
    end
  end

  -- só agora marcamos um scan completo bem-sucedido
  KrononMarketDB.lastScan = now
  scanning = false
  batch = nil

  print(KM_PREFIX .. string.format(L.SCAN_DONE, count))
  FireCallbacks()
end

-- ---------------------------------------------------------------------------
-- Aborta uma varredura em andamento (AH fechou no meio). Não faz merge e
-- libera o lastScan para permitir nova tentativa logo em seguida.
-- ---------------------------------------------------------------------------
local function AbortScan()
  if not scanning then return end
  scanning = false
  batch = nil
  KrononMarketDB.lastScan = nil
end

-- ---------------------------------------------------------------------------
-- Processamento em lotes (recursivo via C_Timer) para não travar o cliente
-- ---------------------------------------------------------------------------
local function ProcessBatch(startIndex, total)
  if not scanning then return end

  local stop = startIndex + BATCH_SIZE
  if stop > total then stop = total end

  for i = startIndex, stop - 1 do
    local info = { C_AuctionHouse.GetReplicateItemInfo(i) }
    local count = info[3]
    local buyoutPrice = info[10]
    local itemID = info[17]

    if itemID
      and C_Item.DoesItemExistByID(itemID)
      and count ~= nil and count > 0
      and buyoutPrice ~= nil and buyoutPrice > 0 then
      local unit = math.floor(buyoutPrice / count)
      if unit > 0 then
        local current = batch[itemID]
        if current == nil or unit < current then
          batch[itemID] = unit
        end
      end
    end
  end

  if stop < total then
    C_Timer.After(BATCH_DELAY, function()
      ProcessBatch(stop, total)
    end)
  else
    EndScan()
  end
end

-- ---------------------------------------------------------------------------
-- Início da varredura
-- ---------------------------------------------------------------------------
local function BeginScan()
  if not CanScan() then return end
  scanning = true
  replicateStarted = false -- o 1º REPLICATE_ITEM_LIST_UPDATE inicia o processamento
  batch = {}
  -- grava lastScan no início (será reescrito no EndScan, ou zerado no AbortScan)
  KrononMarketDB.lastScan = time()
  print(KM_PREFIX .. L.SCAN_START)
  C_AuctionHouse.ReplicateItems()
end

local function HandleReplicateUpdate()
  if not scanning then return end
  -- o evento pode disparar várias vezes por varredura; processamos só o 1º
  -- (replicateStarted), senão abriríamos cadeias de ProcessBatch concorrentes.
  if replicateStarted then return end
  replicateStarted = true
  local total = C_AuctionHouse.GetNumReplicateItems()
  if type(total) ~= "number" or total <= 0 then
    -- nada para processar: finaliza limpo (merge vazio)
    EndScan()
    return
  end
  ProcessBatch(0, total)
end

-- ---------------------------------------------------------------------------
-- API pública
-- ---------------------------------------------------------------------------
function KrononMarket.GetPrice(itemID)
  if type(itemID) ~= "number" then return nil end
  local e = KrononMarketDB and KrononMarketDB.prices and KrononMarketDB.prices[itemID]
  return e and e.p or nil
end

function KrononMarket.GetPriceByLink(link)
  if not link then return nil end
  local id = C_Item.GetItemInfoInstant(link)
  return id and KrononMarket.GetPrice(id) or nil
end

function KrononMarket.GetLastScan()
  return KrononMarketDB and KrononMarketDB.lastScan or nil
end

function KrononMarket.IsScanning()
  return scanning
end

function KrononMarket.RegisterForUpdate(cb)
  if type(cb) == "function" then
    kmCallbacks[#kmCallbacks + 1] = cb
  end
end

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------
local function CountPrices()
  local n = 0
  if KrononMarketDB and KrononMarketDB.prices then
    for _ in pairs(KrononMarketDB.prices) do n = n + 1 end
  end
  return n
end

local function PrintStatus()
  if scanning then
    print(KM_PREFIX .. L.STATUS_SCANNING)
  elseif KrononMarketDB and KrononMarketDB.lastScan then
    local ago = FormatDuration(time() - KrononMarketDB.lastScan)
    print(KM_PREFIX .. string.format(L.STATUS_AGO, ago))
  else
    print(KM_PREFIX .. L.STATUS_NEVER)
  end
  print(KM_PREFIX .. string.format(L.STATUS_ITEMS, CountPrices()))
  if not scanning then
    print(KM_PREFIX .. L.TIP_OPEN_AH)
  end
end

SLASH_KRONONMARKET1 = "/km"
SLASH_KRONONMARKET2 = "/kmarket"
SlashCmdList["KRONONMARKET"] = function()
  PrintStatus()
end

-- ---------------------------------------------------------------------------
-- Eventos
-- ---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")

frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == "KrononMarket" then
      InitDB()
    end
  elseif event == "AUCTION_HOUSE_SHOW" then
    if CanScan() then
      BeginScan()
    end
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    HandleReplicateUpdate()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    AbortScan()
  end
end)
