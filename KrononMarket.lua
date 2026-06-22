-- KrononMarket — coletor de preços da Casa de Leilões do ecossistema Kronon.
-- Escaneia a AH ao abri-la (throttle configurável), guarda um preço unitário
-- robusto (mediana das últimas varreduras) por item e por REINO, e expõe esses
-- valores via API para o KrononBags e outros addons.

local KM_PREFIX = "|cff33ff33KrononMarket|r: "

-- ---------------------------------------------------------------------------
-- A) HARDENING DO LOAD
-- LibStub silencioso: se a KrononLib não estiver presente (ex.: build "nolib"
-- ou libs apagadas), avisamos UMA vez de forma trilíngue e abortamos com
-- elegância — sem registrar eventos nem estourar erro cru.
-- ---------------------------------------------------------------------------
local K = LibStub and LibStub("KrononLib-1.0", true)
if not K then
  print(KM_PREFIX
    .. "faltam bibliotecas (KrononLib) — addon desativado. "
    .. "| missing libraries (KrononLib) — addon disabled. "
    .. "| faltan bibliotecas (KrononLib) — addon desactivado.")
  return
end

-- ---------------------------------------------------------------------------
-- Constantes
-- ---------------------------------------------------------------------------
local DEFAULT_SCAN_THROTTLE = 15 * 60   -- 15 min entre varreduras (account-wide); salvo em DB (configurável)
local BATCH_SIZE = 250                  -- itens processados por lote
local BATCH_DELAY = 0.01                -- pausa entre lotes (segundos)
local SAMPLE_HISTORY = 5                -- amostras (varreduras) mantidas por item
local MIN_STACK = 5                     -- piso de quantidade p/ amostra "confiável" (anti-lowball em commodities)
local MAX_AGE = 30 * 24 * 60 * 60       -- poda: descarta entradas com mais de ~30 dias

-- ---------------------------------------------------------------------------
-- i18n leve: tabela EN base + overlay ptBR/esES, com fallback via metatable
-- (chave inexistente devolve a própria chave). Merge delegado à KrononLib-1.0.
-- ---------------------------------------------------------------------------
local EN = {
  SCAN_START = "Scanning the Auction House…",
  SCAN_DONE = "%d items updated",
  STATUS_NEVER = "never scanned",
  STATUS_AGO = "last scan: %s ago",
  STATUS_ITEMS = "%d items in database",
  STATUS_SCANNING = "scanning in progress…",
  STATUS_REALM = "realm: %s",
  TIP_OPEN_AH = "Open the Auction House to update prices.",
  SCAN_FORCED = "forcing a scan…",
  SCAN_NEED_AH = "the Auction House must be open to scan.",
  SCAN_BUSY = "a scan is already running.",
  ASK_PRICE_HAVE = "%s — %s (updated %s ago)",
  ASK_PRICE_NONE = "%s — no price in database",
  CLEAR_CONFIRM = "this erases %d prices for this realm. Type /km clear confirm to proceed.",
  CLEAR_DONE = "database cleared (%d prices removed).",
  CLEAR_NOTHING = "nothing to clear.",
  HELP_HEADER = "commands:",
  HELP_STATUS = "/km — show status",
  HELP_LINK = "/km [item link] — query an item's price",
  HELP_SCAN = "/km scan — force a scan (AH must be open)",
  HELP_CLEAR = "/km clear — erase this realm's prices",
  HELP_HELP = "/km help — this help",
}

local PT = {
  SCAN_START = "Escaneando a Casa de Leilões…",
  SCAN_DONE = "%d itens atualizados",
  STATUS_NEVER = "nunca escaneado",
  STATUS_AGO = "última varredura: há %s",
  STATUS_ITEMS = "%d itens no banco",
  STATUS_SCANNING = "varredura em andamento…",
  STATUS_REALM = "reino: %s",
  TIP_OPEN_AH = "Abra a Casa de Leilões pra atualizar os preços.",
  SCAN_FORCED = "forçando varredura…",
  SCAN_NEED_AH = "a Casa de Leilões precisa estar aberta pra escanear.",
  SCAN_BUSY = "já há uma varredura em andamento.",
  ASK_PRICE_HAVE = "%s — %s (atualizado há %s)",
  ASK_PRICE_NONE = "%s — sem preço no banco",
  CLEAR_CONFIRM = "isto apaga %d preços deste reino. Digite /km clear confirm pra confirmar.",
  CLEAR_DONE = "banco limpo (%d preços removidos).",
  CLEAR_NOTHING = "nada pra limpar.",
  HELP_HEADER = "comandos:",
  HELP_STATUS = "/km — mostra o status",
  HELP_LINK = "/km [link do item] — consulta o preço de um item",
  HELP_SCAN = "/km scan — força uma varredura (AH precisa estar aberta)",
  HELP_CLEAR = "/km clear — apaga os preços deste reino",
  HELP_HELP = "/km help — esta ajuda",
}

local ES = {
  SCAN_START = "Escaneando la Casa de Subastas…",
  SCAN_DONE = "%d objetos actualizados",
  STATUS_NEVER = "nunca escaneado",
  STATUS_AGO = "último escaneo: hace %s",
  STATUS_ITEMS = "%d objetos en la base",
  STATUS_SCANNING = "escaneo en progreso…",
  STATUS_REALM = "reino: %s",
  TIP_OPEN_AH = "Abre la Casa de Subastas para actualizar los precios.",
  SCAN_FORCED = "forzando escaneo…",
  SCAN_NEED_AH = "la Casa de Subastas debe estar abierta para escanear.",
  SCAN_BUSY = "ya hay un escaneo en curso.",
  ASK_PRICE_HAVE = "%s — %s (actualizado hace %s)",
  ASK_PRICE_NONE = "%s — sin precio en la base",
  CLEAR_CONFIRM = "esto borra %d precios de este reino. Escribe /km clear confirm para confirmar.",
  CLEAR_DONE = "base limpiada (%d precios eliminados).",
  CLEAR_NOTHING = "nada que limpiar.",
  HELP_HEADER = "comandos:",
  HELP_STATUS = "/km — muestra el estado",
  HELP_LINK = "/km [enlace de objeto] — consulta el precio de un objeto",
  HELP_SCAN = "/km scan — fuerza un escaneo (la CS debe estar abierta)",
  HELP_CLEAR = "/km clear — borra los precios de este reino",
  HELP_HELP = "/km help — esta ayuda",
}

local L = K:NewLocale(EN, { ptBR = PT, esES = ES })

-- ---------------------------------------------------------------------------
-- Namespace público
-- ---------------------------------------------------------------------------
KrononMarket = KrononMarket or {}

-- ---------------------------------------------------------------------------
-- Estado interno
-- ---------------------------------------------------------------------------
local scanning = false
local replicateStarted = false -- já começamos a processar o 1º REPLICATE_ITEM_LIST_UPDATE? (evita cadeias concorrentes)
local ahOpen = false           -- a Casa de Leilões está aberta agora?
-- batch: [itemID] = { min = menor unitário (qualquer qtd), floored = menor unitário com qtd >= MIN_STACK }
local batch = nil
local marketBus = K.NewEventBus()

-- ---------------------------------------------------------------------------
-- Util: dinheiro e duração
-- ---------------------------------------------------------------------------
local function Money(copper)
  if type(copper) ~= "number" then return "?" end
  if GetCoinTextureString then
    local ok, s = pcall(GetCoinTextureString, copper)
    if ok and s then return s end
  end
  return tostring(copper) .. "c"
end

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
-- E) SEPARAÇÃO POR REINO + SavedVariables
-- Estrutura nova: KrononMarketDB.realms[realm] = { prices = {...}, lastScan = n }
-- A API pública abstrai o reino — KrononBags não precisa mudar.
-- ---------------------------------------------------------------------------
local function GetNormalizedRealm()
  local r
  if GetNormalizedRealmName then
    local ok, v = pcall(GetNormalizedRealmName)
    if ok then r = v end
  end
  if (not r or r == "") and GetRealmName then
    local ok, v = pcall(GetRealmName)
    if ok then r = v end
  end
  if not r or r == "" then r = "Unknown" end
  return r
end

local function GetRealmDB()
  if type(KrononMarketDB) ~= "table" then KrononMarketDB = {} end
  if type(KrononMarketDB.realms) ~= "table" then KrononMarketDB.realms = {} end
  local realm = GetNormalizedRealm()
  local rdb = KrononMarketDB.realms[realm]
  if type(rdb) ~= "table" then
    rdb = { prices = {} }
    KrononMarketDB.realms[realm] = rdb
  end
  if type(rdb.prices) ~= "table" then rdb.prices = {} end
  return rdb
end

local function GetThrottle()
  local t = KrononMarketDB and KrononMarketDB.scanThrottle
  if type(t) == "number" and t > 0 then return t end
  return DEFAULT_SCAN_THROTTLE
end

-- Inicializa o DB e MIGRA o formato antigo (prices/lastScan account-wide) para
-- o reino ATUAL, sem apagar nada. Chamado em PLAYER_LOGIN (reino já disponível).
local function InitDB()
  if type(KrononMarketDB) ~= "table" then KrononMarketDB = {} end
  if type(KrononMarketDB.scanThrottle) ~= "number" then
    KrononMarketDB.scanThrottle = DEFAULT_SCAN_THROTTLE
  end
  if type(KrononMarketDB.realms) ~= "table" then KrononMarketDB.realms = {} end

  -- Migração: prices antigos (account-wide, formato {p,t}) → reino atual.
  if type(KrononMarketDB.prices) == "table" and next(KrononMarketDB.prices) ~= nil then
    local rdb = GetRealmDB()
    local now = time()
    for itemID, e in pairs(KrononMarketDB.prices) do
      if type(e) == "table" and type(e.p) == "number" and e.p > 0 then
        if rdb.prices[itemID] == nil then
          rdb.prices[itemID] = { p = e.p, t = (type(e.t) == "number" and e.t) or now, s = { e.p } }
        end
      end
    end
    if type(KrononMarketDB.lastScan) == "number" and rdb.lastScan == nil then
      rdb.lastScan = KrononMarketDB.lastScan
    end
    -- só removemos as chaves antigas DEPOIS de copiar tudo
    KrononMarketDB.prices = nil
    KrononMarketDB.lastScan = nil
  else
    -- nada a migrar; garante que chaves legadas vazias não fiquem penduradas
    KrononMarketDB.prices = nil
    KrononMarketDB.lastScan = nil
  end
end

-- ---------------------------------------------------------------------------
-- F) PREÇO ROBUSTO: mediana das amostras (uma amostra por varredura).
-- ---------------------------------------------------------------------------
local function Median(samples)
  local n = #samples
  if n == 0 then return nil end
  local copy = {}
  for i = 1, n do copy[i] = samples[i] end
  table.sort(copy)
  if n % 2 == 1 then
    return copy[(n + 1) / 2]
  end
  local a, b = copy[n / 2], copy[n / 2 + 1]
  return math.floor((a + b) / 2)
end

-- Poda entradas mais antigas que MAX_AGE (ou malformadas).
local function PruneOld(rdb, now)
  for itemID, e in pairs(rdb.prices) do
    if type(e) ~= "table" or type(e.t) ~= "number" or (now - e.t) > MAX_AGE then
      rdb.prices[itemID] = nil
    end
  end
end

-- ---------------------------------------------------------------------------
-- Throttle / pré-condições (por reino)
-- ---------------------------------------------------------------------------
local function CanScan()
  if scanning then return false end
  if type(KrononMarketDB) ~= "table" then return false end
  local rdb = GetRealmDB()
  if rdb.lastScan == nil then return true end
  return (time() - rdb.lastScan) > GetThrottle()
end

-- ---------------------------------------------------------------------------
-- MERGE no DB do que foi coletado em `batch`. NUNCA apaga itens não vistos.
-- Para cada item escolhe a amostra confiável (floored, com qtd >= MIN_STACK)
-- ou cai no menor unitário absoluto; empilha no histórico e recalcula a mediana.
-- Retorna a contagem de itens mesclados.
-- ---------------------------------------------------------------------------
local function MergeBatch(now)
  local rdb = GetRealmDB()
  local count = 0
  if type(batch) == "table" then
    for itemID, b in pairs(batch) do
      local sample = b.floored or b.min
      if type(sample) == "number" and sample > 0 then
        local e = rdb.prices[itemID]
        if type(e) ~= "table" then e = { s = {} }; rdb.prices[itemID] = e end
        if type(e.s) ~= "table" then e.s = {} end
        e.s[#e.s + 1] = sample
        while #e.s > SAMPLE_HISTORY do table.remove(e.s, 1) end
        e.p = Median(e.s)
        e.t = now
        count = count + 1
      end
    end
  end
  return count
end

-- ---------------------------------------------------------------------------
-- Finalização da varredura: faz MERGE, grava lastScan (SÓ aqui), poda e avisa.
-- ---------------------------------------------------------------------------
local function EndScan()
  if not scanning then return end
  local now = time()
  local count = MergeBatch(now)
  local rdb = GetRealmDB()
  rdb.lastScan = now           -- (B) lastScan só é gravado num scan que CHEGOU ao fim
  PruneOld(rdb, now)
  scanning = false
  batch = nil
  print(KM_PREFIX .. string.format(L.SCAN_DONE, count))
  marketBus:Fire(count, now)   -- (D) resumo: quantos itens, quando
end

-- ---------------------------------------------------------------------------
-- B) AbortScan (AH fechou no meio): NÃO descarta o lote parcial — mescla o que
-- já foi coletado. NÃO grava lastScan, pra permitir um rescan imediato.
-- ---------------------------------------------------------------------------
local function AbortScan()
  if not scanning then return end
  local now = time()
  local count = MergeBatch(now)
  scanning = false
  batch = nil
  if count > 0 then
    marketBus:Fire(count, now)
  end
end

-- ---------------------------------------------------------------------------
-- Processamento em lotes (recursivo via C_Timer) para não travar o cliente.
-- G) COMMODITIES: pela pesquisa, commodities APARECEM no ReplicateItems e o
-- buyoutPrice (índice 10) é o TOTAL do lote — logo floor(buyout/count) já é o
-- unitário correto, tanto p/ mats quanto p/ gear (gear tem count==1). NÃO
-- ramificamos por tipo. O piso MIN_STACK serve só de defesa anti-lowball:
-- guardamos também a menor amostra com qtd >= MIN_STACK e a preferimos no merge,
-- caindo no mínimo absoluto quando não houver (caso típico de equipamentos).
-- ---------------------------------------------------------------------------
local function ProcessBatch(startIndex, total)
  if not scanning then return end

  local stop = startIndex + BATCH_SIZE
  if stop > total then stop = total end

  for i = startIndex, stop - 1 do
    local count, buyoutPrice, itemID
    local ok = pcall(function()
      local info = { C_AuctionHouse.GetReplicateItemInfo(i) }
      count = info[3]
      buyoutPrice = info[10]
      itemID = info[17]
    end)

    if ok and itemID
      and type(count) == "number" and count > 0
      and type(buyoutPrice) == "number" and buyoutPrice > 0 then

      local exists = true
      if C_Item and C_Item.DoesItemExistByID then
        local ok2, r = pcall(C_Item.DoesItemExistByID, itemID)
        exists = ok2 and r and true or false
      end

      if exists then
        local unit = math.floor(buyoutPrice / count)
        if unit > 0 then
          local b = batch[itemID]
          if b == nil then b = {}; batch[itemID] = b end
          if b.min == nil or unit < b.min then b.min = unit end
          if count >= MIN_STACK and (b.floored == nil or unit < b.floored) then
            b.floored = unit
          end
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
-- Início da varredura. force=true ignora o throttle (usado por /km scan).
-- (B) NÃO grava mais lastScan aqui — só o EndScan grava.
-- ---------------------------------------------------------------------------
local function BeginScan(force)
  if scanning then return false end
  if not force and not CanScan() then return false end
  scanning = true
  replicateStarted = false -- o 1º REPLICATE_ITEM_LIST_UPDATE inicia o processamento
  batch = {}
  print(KM_PREFIX .. L.SCAN_START)
  local ok = pcall(C_AuctionHouse.ReplicateItems)
  if not ok then
    -- falhou ao pedir a réplica: desfaz o estado pra não travar
    scanning = false
    batch = nil
    return false
  end
  return true
end

local function HandleReplicateUpdate()
  if not scanning then return end
  -- o evento pode disparar várias vezes por varredura; processamos só o 1º
  -- (replicateStarted), senão abriríamos cadeias de ProcessBatch concorrentes.
  if replicateStarted then return end
  replicateStarted = true
  local total
  local ok, v = pcall(C_AuctionHouse.GetNumReplicateItems)
  if ok then total = v end
  if type(total) ~= "number" or total <= 0 then
    EndScan() -- nada para processar: finaliza limpo (merge vazio)
    return
  end
  ProcessBatch(0, total)
end

-- ---------------------------------------------------------------------------
-- API pública (compatível: GetPrice devolve só o número)
-- ---------------------------------------------------------------------------
function KrononMarket.GetPrice(itemID)
  if type(itemID) ~= "number" then return nil end
  local rdb = KrononMarketDB and KrononMarketDB.realms
  if not rdb then return nil end
  local realm = GetNormalizedRealm()
  local r = rdb[realm]
  local e = r and r.prices and r.prices[itemID]
  if type(e) == "table" and type(e.p) == "number" then return e.p end
  return nil
end

-- D) GetPriceInfo: número + carimbo de tempo + idade em segundos.
function KrononMarket.GetPriceInfo(itemID)
  if type(itemID) ~= "number" then return nil end
  local rdb = KrononMarketDB and KrononMarketDB.realms
  if not rdb then return nil end
  local realm = GetNormalizedRealm()
  local r = rdb[realm]
  local e = r and r.prices and r.prices[itemID]
  if type(e) ~= "table" or type(e.p) ~= "number" then return nil end
  local t = type(e.t) == "number" and e.t or nil
  return {
    price = e.p,
    timestamp = t,
    ageSeconds = t and (time() - t) or nil,
  }
end

function KrononMarket.GetPriceByLink(link)
  if not link then return nil end
  local id = C_Item.GetItemInfoInstant(link)
  return id and KrononMarket.GetPrice(id) or nil
end

function KrononMarket.GetLastScan()
  if type(KrononMarketDB) ~= "table" then return nil end
  local rdb = GetRealmDB()
  return rdb.lastScan
end

function KrononMarket.IsScanning()
  return scanning
end

function KrononMarket.RegisterForUpdate(cb)
  return marketBus:Register(cb)
end

-- ---------------------------------------------------------------------------
-- C) Slash command com subcomandos
-- ---------------------------------------------------------------------------
local function CountPrices()
  local n = 0
  if type(KrononMarketDB) == "table" then
    local rdb = GetRealmDB()
    for _ in pairs(rdb.prices) do n = n + 1 end
  end
  return n
end

local function PrintStatus()
  print(KM_PREFIX .. string.format(L.STATUS_REALM, GetNormalizedRealm()))
  if scanning then
    print(KM_PREFIX .. L.STATUS_SCANNING)
  else
    local last = KrononMarket.GetLastScan()
    if last then
      print(KM_PREFIX .. string.format(L.STATUS_AGO, FormatDuration(time() - last)))
    else
      print(KM_PREFIX .. L.STATUS_NEVER)
    end
  end
  print(KM_PREFIX .. string.format(L.STATUS_ITEMS, CountPrices()))
  if not scanning then
    print(KM_PREFIX .. L.TIP_OPEN_AH)
  end
end

local function PrintHelp()
  print(KM_PREFIX .. L.HELP_HEADER)
  print(KM_PREFIX .. L.HELP_STATUS)
  print(KM_PREFIX .. L.HELP_LINK)
  print(KM_PREFIX .. L.HELP_SCAN)
  print(KM_PREFIX .. L.HELP_CLEAR)
  print(KM_PREFIX .. L.HELP_HELP)
end

local function QueryLinkCommand(link)
  local price = KrononMarket.GetPriceByLink(link)
  if type(price) == "number" and price > 0 then
    local id = C_Item.GetItemInfoInstant(link)
    local info = id and KrononMarket.GetPriceInfo(id)
    local age = (info and info.ageSeconds) or 0
    print(KM_PREFIX .. string.format(L.ASK_PRICE_HAVE, link, Money(price), FormatDuration(age)))
  else
    print(KM_PREFIX .. string.format(L.ASK_PRICE_NONE, link))
  end
end

local function ScanCommand()
  if scanning then
    print(KM_PREFIX .. L.SCAN_BUSY)
    return
  end
  if not ahOpen then
    print(KM_PREFIX .. L.SCAN_NEED_AH)
    return
  end
  print(KM_PREFIX .. L.SCAN_FORCED)
  BeginScan(true) -- força: ignora o throttle
end

local function ClearCommand(rest)
  if rest and rest:lower() == "confirm" then
    local rdb = GetRealmDB()
    local n = CountPrices()
    rdb.prices = {}
    rdb.lastScan = nil
    print(KM_PREFIX .. string.format(L.CLEAR_DONE, n))
    marketBus:Fire(0, time())
  else
    local n = CountPrices()
    if n > 0 then
      print(KM_PREFIX .. string.format(L.CLEAR_CONFIRM, n))
    else
      print(KM_PREFIX .. L.CLEAR_NOTHING)
    end
  end
end

SLASH_KRONONMARKET1 = "/km"
SLASH_KRONONMARKET2 = "/kmarket"
SlashCmdList["KRONONMARKET"] = function(msg)
  msg = msg and strtrim(msg) or ""

  if msg == "" then
    PrintStatus()
    return
  end

  -- link de item (contém o hyperlink |Hitem:) tem precedência sobre tokens
  if msg:find("|Hitem:", 1, true) then
    QueryLinkCommand(msg)
    return
  end

  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()

  if cmd == "status" then
    PrintStatus()
  elseif cmd == "scan" then
    ScanCommand()
  elseif cmd == "clear" then
    ClearCommand(rest)
  elseif cmd == "help" then
    PrintHelp()
  elseif cmd:match("^%d+$") then
    -- conveniência: /km <itemID>
    local id = tonumber(cmd)
    local info = id and KrononMarket.GetPriceInfo(id)
    if info and info.price then
      print(KM_PREFIX .. string.format(L.ASK_PRICE_HAVE, "item:" .. id, Money(info.price), FormatDuration(info.ageSeconds or 0)))
    else
      print(KM_PREFIX .. string.format(L.ASK_PRICE_NONE, "item:" .. id))
    end
  else
    PrintHelp()
  end
end

-- ---------------------------------------------------------------------------
-- Eventos
-- ---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")

frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    InitDB() -- reino já disponível: inicializa e migra o DB legado
  elseif event == "AUCTION_HOUSE_SHOW" then
    ahOpen = true
    if CanScan() then
      BeginScan()
    end
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    HandleReplicateUpdate()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    ahOpen = false
    AbortScan()
  end
end)
