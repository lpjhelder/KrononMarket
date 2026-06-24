-- KrononMarket — coletor de preços da Casa de Leilões do ecossistema Kronon.
-- Escaneia a AH ao abri-la via BROWSE QUERY incremental (o mesmo fluxo do scan
-- padrão do Auctionator): envia uma busca "tudo", pagina os resultados e guarda
-- um preço unitário robusto (mediana das últimas varreduras) por item e por
-- REINO, expondo esses valores via API para o KrononBags e outros addons.
-- O browse NÃO tem o cooldown de 15 min do antigo ReplicateItems — só um throttle
-- curto da Blizzard, respeitado via IsThrottledMessageSystemReady/eventos.

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
local DEFAULT_SCAN_THROTTLE = 60          -- throttle CLIENT-SIDE curto (1 min) entre varreduras automáticas ao reabrir a AH; salvo no DB (configurável). /km scan ignora.
local OLD_DEFAULT_SCAN_THROTTLE = 15 * 60 -- default legado (era do ReplicateItems); migrado pro novo na InitDB
local SUMMARY_BATCH_SIZE = 500            -- tamanho de página do browse; usado só como estimativa de "ainda falta uma página" no progresso
local SAMPLE_HISTORY = 5                  -- amostras (varreduras) mantidas por item
local MIN_STACK = 5                       -- piso de quantidade p/ amostra "confiável" (anti-lowball em commodities)
local MAX_AGE = 30 * 24 * 60 * 60         -- poda: descarta entradas com mais de ~30 dias
local MAX_BROWSE_RETRIES = 5              -- teto de reenvios de browse antes de abortar (anti-loop em falha/drop)

-- ---------------------------------------------------------------------------
-- i18n leve: tabela EN base + overlay ptBR/esES, com fallback via metatable
-- (chave inexistente devolve a própria chave). Merge delegado à KrononLib-1.0.
-- ---------------------------------------------------------------------------
local EN = {
  SCAN_QUERYING = "Querying the Auction House…",
  SCAN_DONE = "%d items updated",
  SCAN_FAILED = "The Auction House didn't respond. Try again in a moment.",
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
  HELP_BAR = "/km bar — toggle the scan progress bar",
  HELP_HELP = "/km help — this help",
  BAR_TEXT = "Scanning the Auction House… %d%%",
  BAR_ON = "progress bar enabled.",
  BAR_OFF = "progress bar disabled.",
  TREND_UP = "↑ %d%% above average",
  TREND_DOWN = "↓ %d%% below average",
  TREND_STABLE = "→ stable",
}

local PT = {
  SCAN_QUERYING = "Consultando a Casa de Leilões…",
  SCAN_DONE = "%d itens atualizados",
  SCAN_FAILED = "A Casa de Leilões não respondeu. Tente de novo em instantes.",
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
  HELP_BAR = "/km bar — liga/desliga a barra de progresso da varredura",
  HELP_HELP = "/km help — esta ajuda",
  BAR_TEXT = "Varrendo a Casa de Leilões… %d%%",
  BAR_ON = "barra de progresso ligada.",
  BAR_OFF = "barra de progresso desligada.",
  TREND_UP = "↑ %d%% acima da média",
  TREND_DOWN = "↓ %d%% abaixo da média",
  TREND_STABLE = "→ estável",
}

local ES = {
  SCAN_QUERYING = "Consultando la Casa de Subastas…",
  SCAN_DONE = "%d objetos actualizados",
  SCAN_FAILED = "La Casa de Subastas no respondió. Inténtalo de nuevo en un momento.",
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
  HELP_BAR = "/km bar — activa/desactiva la barra de progreso del escaneo",
  HELP_HELP = "/km help — esta ayuda",
  BAR_TEXT = "Escaneando la Casa de Subastas… %d%%",
  BAR_ON = "barra de progreso activada.",
  BAR_OFF = "barra de progreso desactivada.",
  TREND_UP = "↑ %d%% sobre la media",
  TREND_DOWN = "↓ %d%% bajo la media",
  TREND_STABLE = "→ estable",
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
local ahOpen = false           -- a Casa de Leilões está aberta agora?
-- batch: [itemID] = { min = menor unitário (qualquer qtd), floored = menor unitário com qtd >= MIN_STACK }
local batch = nil
-- fila de throttle: ação aguardando o sistema ficar pronto (no máx. uma por vez)
local queuedAction = nil
-- última ação de browse enviada (pra reenviar em caso de falha/drop)
local lastBrowseAction = nil
-- contador de reenvios de browse na varredura atual (CAP em MAX_BROWSE_RETRIES)
local browseRetries = 0
-- token de geração da varredura: invalida watchdogs de scans antigos
local scanGen = 0
local marketBus = K.NewEventBus()

-- ---------------------------------------------------------------------------
-- A) FEEDBACK DE PROGRESSO
-- Barramento dedicado ao progresso (separado do marketBus de update). Cada
-- callback roda em pcall (garantido pelo EventBus da KrononLib). O estado
-- scanCurrent/scanTotal é a ÚNICA fonte de verdade, consumida tanto pela API
-- pública quanto pela barra flutuante. Durante o browse, total pode ser
-- indeterminado (0) até HasFullBrowseResults; é o esperado.
-- ---------------------------------------------------------------------------
local progressBus = K.NewEventBus()
local scanCurrent, scanTotal = 0, 0

-- Dispara o progresso para todos os assinantes e atualiza o estado público.
local function FireProgress(current, total)
  scanCurrent = (type(current) == "number" and current >= 0) and current or 0
  scanTotal = (type(total) == "number" and total >= 0) and total or 0
  progressBus:Fire(scanCurrent, scanTotal)
end

-- ---------------------------------------------------------------------------
-- B) BARRA DE PROGRESSO FLUTUANTE (UI própria, somente display — sem ações
-- protegidas/inseguras, então não há risco de taint). Aparece no BeginScan,
-- atualiza pela MESMA fonte de progresso (progressBus) e some no fim. Quando o
-- total ainda é indeterminado (browse em andamento, antes do 1º lote), a barra
-- entra em modo "indeterminado" (sweep) com o texto "Consultando…".
-- ---------------------------------------------------------------------------
local progressBar -- frame criado sob demanda (lazy)
local BAR_DEFAULTS = { enabled = true, point = "TOP", relPoint = "TOP", x = 0, y = -120 }

-- Lê/normaliza as preferências da barra em KrononMarketDB.bar (defaults sensatos).
local function BarPrefs()
  if type(KrononMarketDB) ~= "table" then KrononMarketDB = {} end
  if type(KrononMarketDB.bar) ~= "table" then KrononMarketDB.bar = {} end
  local b = KrononMarketDB.bar
  if type(b.enabled) ~= "boolean" then b.enabled = BAR_DEFAULTS.enabled end
  if type(b.point) ~= "string" then b.point = BAR_DEFAULTS.point end
  if type(b.relPoint) ~= "string" then b.relPoint = BAR_DEFAULTS.relPoint end
  if type(b.x) ~= "number" then b.x = BAR_DEFAULTS.x end
  if type(b.y) ~= "number" then b.y = BAR_DEFAULTS.y end
  return b
end

local function SaveBarPosition()
  if not progressBar then return end
  local prefs = BarPrefs()
  local point, _, relPoint, x, y = progressBar:GetPoint()
  if point then
    prefs.point = point
    prefs.relPoint = relPoint or point
    prefs.x = math.floor((x or 0) + 0.5)
    prefs.y = math.floor((y or 0) + 0.5)
  end
end

-- Cria o frame na primeira necessidade (evita custo pra quem nunca escaneia).
local function EnsureBar()
  if progressBar then return progressBar end
  local prefs = BarPrefs()
  local f = CreateFrame("Frame", "KrononMarketProgressBar", UIParent, "BackdropTemplate")
  f:SetSize(260, 34)
  f:SetPoint(prefs.point, UIParent, prefs.relPoint, prefs.x, prefs.y)
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveBarPosition()
  end)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.85)
  end

  local sb = CreateFrame("StatusBar", nil, f)
  sb:SetPoint("TOPLEFT", 6, -6)
  sb:SetPoint("BOTTOMRIGHT", -6, 6)
  sb:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  sb:SetStatusBarColor(0.2, 0.8, 0.2)
  sb:SetMinMaxValues(0, 1)
  sb:SetValue(0)
  f.bar = sb

  local txt = sb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  txt:SetPoint("CENTER")
  f.text = txt

  -- Modo indeterminado: enquanto não há total conhecido, a barra "varre" pra
  -- dar sinal de vida imediato (1-2s) assim que a query é enviada.
  f.indeterminate = false
  f.sweep = 0
  f:SetScript("OnUpdate", function(self, elapsed)
    if self.indeterminate then
      self.sweep = ((self.sweep or 0) + (elapsed or 0) * 0.8) % 1
      self.bar:SetValue(self.sweep)
    end
  end)

  f:Hide()
  progressBar = f
  return f
end

local function UpdateBar(current, total)
  local f = EnsureBar()
  total = (type(total) == "number" and total > 0) and total or 0
  current = (type(current) == "number" and current >= 0) and current or 0
  if total > 0 then
    f.indeterminate = false
    local pct = current / total
    if pct > 1 then pct = 1 end
    f.bar:SetValue(pct)
    f.text:SetText(string.format(L.BAR_TEXT, math.floor(pct * 100 + 0.5)))
  else
    -- total indeterminado: sweep + texto "Consultando…"
    f.indeterminate = true
    f.text:SetText(L.SCAN_QUERYING)
  end
end

local function ShowBar()
  local prefs = BarPrefs()
  if not prefs.enabled then return end
  local f = EnsureBar()
  UpdateBar(scanCurrent, scanTotal)
  f:Show()
end

local function HideBar()
  if progressBar then progressBar:Hide() end
end

-- A barra é só mais um assinante do progresso: usa exatamente a mesma fonte
-- que a API pública (consistência garantida).
progressBus:Register(function(current, total)
  if progressBar and progressBar:IsShown() then
    UpdateBar(current, total)
  end
end)

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
-- Estrutura: KrononMarketDB.realms[realm] = { prices = {...}, lastScan = n }
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
  -- Migração do throttle: quem tinha o default legado (15 min, do ReplicateItems)
  -- passa pro novo throttle curto — o browse não precisa do cooldown longo.
  if KrononMarketDB.scanThrottle == OLD_DEFAULT_SCAN_THROTTLE then
    KrononMarketDB.scanThrottle = DEFAULT_SCAN_THROTTLE
  end
  if type(KrononMarketDB.scanThrottle) ~= "number" then
    KrononMarketDB.scanThrottle = DEFAULT_SCAN_THROTTLE
  end
  if type(KrononMarketDB.realms) ~= "table" then KrononMarketDB.realms = {} end
  BarPrefs() -- garante os defaults da barra de progresso

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
-- Throttle CLIENT-SIDE curto: evita re-escanear a cada reabertura da AH. NÃO é
-- mais o cooldown de 15 min imposto pela Blizzard (esse era só do Replicate).
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
  FireProgress(scanTotal, scanTotal) -- último disparo: current == total (ainda scanning=true)
  scanning = false
  batch = nil
  queuedAction = nil
  lastBrowseAction = nil
  HideBar()
  print(KM_PREFIX .. string.format(L.SCAN_DONE, count))
  marketBus:Fire(count, now)   -- (D) resumo: quantos itens, quando
end

-- ---------------------------------------------------------------------------
-- AbortScan (AH fechou no meio): NÃO descarta o lote parcial — mescla o que já
-- foi coletado. NÃO grava lastScan, pra permitir um rescan imediato.
-- ---------------------------------------------------------------------------
local function AbortScan()
  if not scanning then return end
  local now = time()
  local count = MergeBatch(now)
  -- progresso final no ponto em que paramos: current == total = quanto coletamos
  FireProgress(scanCurrent, scanCurrent)
  scanning = false
  batch = nil
  queuedAction = nil
  lastBrowseAction = nil
  HideBar()
  if count > 0 then
    marketBus:Fire(count, now)
  end
end

-- ---------------------------------------------------------------------------
-- THROTTLE curto (Queue): roda a ação agora se o sistema estiver pronto, senão
-- enfileira (no máx. uma) até AUCTION_HOUSE_THROTTLED_SYSTEM_READY. É o mesmo
-- padrão do Auctionator (IsThrottledMessageSystemReady + evento Ready).
-- ---------------------------------------------------------------------------
local function RunThrottled(action)
  if type(action) ~= "function" then return end
  queuedAction = action
  local ok, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
  if ok and ready then
    local a = queuedAction
    queuedAction = nil
    a()
  end
end

-- Dispara a ação enfileirada quando o sistema sinaliza que está pronto.
local function FlushThrottled()
  if not scanning then return end
  if queuedAction then
    local a = queuedAction
    queuedAction = nil
    a()
  end
end

-- ---------------------------------------------------------------------------
-- BROWSE QUERY incremental
-- Fluxo: SendBrowseQuery(query "tudo") -> AUCTION_HOUSE_BROWSE_RESULTS_UPDATED /
-- _ADDED -> GetBrowseResults() -> extrai itemKey.itemID + minPrice (unitário),
-- guardando o MENOR por itemID -> se not HasFullBrowseResults() pagina com
-- RequestMoreBrowseResults() -> ao completar, EndScan().
-- ---------------------------------------------------------------------------

-- Reconstrói o batch a partir do estado completo de GetBrowseResults() (que é
-- cumulativo entre páginas). Idempotente: reprocessar o mesmo conjunto só
-- recalcula o mesmo mínimo. Defensivo contra itemKey/campos ausentes.
local function ScanActionSendQuery() end   -- forward decl (definida abaixo)
local function ScanActionRequestMore() end -- forward decl (definida abaixo)

local function ProcessBrowse()
  if not scanning then return end

  local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
  if not ok or type(results) ~= "table" then results = {} end

  -- G) GEAR vs COMMODITY: gear aparece em vários BrowseResultInfo pro mesmo
  -- itemID (um por itemLevel); commodity vem num único itemKey só com itemID.
  -- Em ambos minPrice já é UNITÁRIO. Guardamos o MENOR minPrice por itemID e,
  -- como defesa anti-lowball, também o menor com totalQuantity >= MIN_STACK.
  local fresh = {}
  for _, r in ipairs(results) do
    if type(r) == "table" and type(r.itemKey) == "table" then
      local itemID = r.itemKey.itemID
      local unit = r.minPrice
      local qty = r.totalQuantity
      if type(itemID) == "number" and itemID > 0
        and type(unit) == "number" and unit > 0
        and type(qty) == "number" and qty > 0 then
        local b = fresh[itemID]
        if b == nil then b = {}; fresh[itemID] = b end
        if b.min == nil or unit < b.min then b.min = unit end
        if qty >= MIN_STACK and (b.floored == nil or unit < b.floored) then
          b.floored = unit
        end
      end
    end
  end
  batch = fresh
  browseRetries = 0 -- lote chegou: progresso real, zera o CAP de reenvios

  -- A) progresso: current = nº de resultados de browse lidos até agora; total é
  -- uma estimativa (enquanto não completou, sabemos que há ao menos +1 página).
  local n = #results
  local okFull, full = pcall(C_AuctionHouse.HasFullBrowseResults)
  full = (okFull and full) and true or false
  local total = full and n or (n + SUMMARY_BATCH_SIZE)
  FireProgress(n, total)

  if full then
    EndScan()
  else
    RunThrottled(ScanActionRequestMore)
  end
end

-- Envia a query "tudo" (todos os campos vazios = casa inteira). Guarda-se como
-- lastBrowseAction pra reenviar caso a Blizzard descarte/falhe a mensagem.
function ScanActionSendQuery()
  if not scanning then return end
  lastBrowseAction = ScanActionSendQuery
  -- Algumas builds rejeitam browse query com sorts vazio (AUCTION_HOUSE_BROWSE_FAILURE).
  -- Usamos um sort por preço quando o Enum existe; senão cai no {} de antes (sem quebrar).
  local E = Enum and Enum.AuctionHouseSortOrder
  local sorts = (E and E.Price) and { { sortOrder = E.Price, reverseSort = false } } or {}
  local query = { searchString = "", sorts = sorts, filters = {}, itemClassFilters = {} }
  pcall(C_AuctionHouse.SendBrowseQuery, query)
end

-- Pede a próxima página (grupo de 500). Idem: registrada como lastBrowseAction.
function ScanActionRequestMore()
  if not scanning then return end
  lastBrowseAction = ScanActionRequestMore
  pcall(C_AuctionHouse.RequestMoreBrowseResults)
end

-- ---------------------------------------------------------------------------
-- Início da varredura. force=true ignora o throttle (usado por /km scan).
-- NÃO grava lastScan aqui — só o EndScan grava.
-- ---------------------------------------------------------------------------
local function BeginScan(force)
  if scanning then return false end
  if not force and not CanScan() then return false end
  scanning = true
  batch = {}
  queuedAction = nil
  lastBrowseAction = nil
  browseRetries = 0
  scanGen = (scanGen or 0) + 1
  local gen = scanGen
  scanCurrent, scanTotal = 0, 0
  print(KM_PREFIX .. L.SCAN_QUERYING) -- feedback IMEDIATO em chat
  ShowBar()
  FireProgress(0, 0)                  -- barra ganha vida na hora (modo indeterminado)
  RunThrottled(ScanActionSendQuery)   -- respeita o throttle curto antes de enviar
  -- WATCHDOG: se NENHUM evento de browse chegar (nada coletado) na mesma geração,
  -- destrava abortando. Não mata um scan que progrediu (scanCurrent > 0) nem um
  -- scan novo iniciado depois (scanGen diferente).
  if C_Timer and C_Timer.After then
    C_Timer.After(30, function()
      if scanning and scanGen == gen and (scanCurrent or 0) <= 0 then
        print(KM_PREFIX .. L.SCAN_FAILED)
        AbortScan()
      end
    end)
  end
  return true
end

-- Reenvia a última ação de browse após falha/drop (sem reiniciar o scan).
-- CAP: após MAX_BROWSE_RETRIES tentativas sem progresso, aborta e avisa (UMA vez)
-- em vez de reenviar pra sempre. O contador zera quando um lote chega (ProcessBrowse).
local function RetryBrowse()
  if not scanning then return end
  browseRetries = (browseRetries or 0) + 1
  if browseRetries > MAX_BROWSE_RETRIES then
    print(KM_PREFIX .. L.SCAN_FAILED)
    AbortScan()
    return
  end
  if type(lastBrowseAction) == "function" then
    RunThrottled(lastBrowseAction)
  end
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

-- D2) TENDÊNCIA DE PREÇO: lê o histórico curto (e.s — últimas ~5 amostras por
-- reino) JÁ gravado e compara o preço ATUAL (a mediana que GetPrice devolve)
-- com a referência das amostras ANTERIORES (média de tudo menos a última).
-- Não altera GetPrice nem o formato salvo — só LÊ o que MergeBatch já empilhou.
-- Retorna { dir = "up"|"down"|"stable", pct = variação % do atual vs a referência,
-- cur = preço atual, ref = referência } ou nil se houver < 2 amostras ou
-- referência <= 0. Defensivo: sem divisão por zero, sempre nil em caso ambíguo.
function KrononMarket.GetPriceTrend(itemID)
  if type(itemID) ~= "number" then return nil end
  local rdb = KrononMarketDB and KrononMarketDB.realms
  if not rdb then return nil end
  local realm = GetNormalizedRealm()
  local r = rdb[realm]
  local e = r and r.prices and r.prices[itemID]
  if type(e) ~= "table" or type(e.s) ~= "table" then return nil end
  local s = e.s
  local n = #s
  if n < 2 then return nil end -- histórico insuficiente

  -- preço atual: a mediana que GetPrice devolve; cai pra última amostra se faltar
  local cur = (type(e.p) == "number" and e.p > 0) and e.p or s[n]
  if type(cur) ~= "number" or cur <= 0 then return nil end

  -- referência: média das amostras ANTERIORES (todas menos a última gravada)
  local sum, cnt = 0, 0
  for i = 1, n - 1 do
    local v = s[i]
    if type(v) == "number" and v > 0 then
      sum = sum + v
      cnt = cnt + 1
    end
  end
  if cnt == 0 then return nil end
  local ref = sum / cnt
  if ref <= 0 then return nil end -- guarda contra divisão por zero

  local pct = (cur - ref) / ref * 100
  local dir
  if pct > 5 then
    dir = "up"
  elseif pct < -5 then
    dir = "down"
  else
    dir = "stable"
  end
  return { dir = dir, pct = pct, cur = cur, ref = ref }
end

-- GetPriceTrendByLink: resolve o itemID do link e delega a GetPriceTrend.
function KrononMarket.GetPriceTrendByLink(link)
  if not link then return nil end
  local id = C_Item.GetItemInfoInstant(link)
  return id and KrononMarket.GetPriceTrend(id) or nil
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

-- A) API DE PROGRESSO (contrato consumido pelo KrononBags).
-- RegisterForProgress(fn): fn é chamado como fn(current, total) a cada lote
-- durante a varredura — sempre via pcall (garantido pelo EventBus).
function KrononMarket.RegisterForProgress(fn)
  return progressBus:Register(fn)
end

-- GetScanProgress(): retorna (scanning, current, total). (false, 0, 0) se nunca
-- escaneou nesta sessão.
function KrononMarket.GetScanProgress()
  return scanning, scanCurrent, scanTotal
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
  print(KM_PREFIX .. L.HELP_BAR)
  print(KM_PREFIX .. L.HELP_HELP)
end

-- Liga/desliga a barra de progresso (preferência salva em KrononMarketDB.bar).
local function BarCommand()
  local prefs = BarPrefs()
  prefs.enabled = not prefs.enabled
  if prefs.enabled then
    print(KM_PREFIX .. L.BAR_ON)
    if scanning then ShowBar() end
  else
    print(KM_PREFIX .. L.BAR_OFF)
    HideBar()
  end
end

-- Formata a tendência pra exibição no chat (ou nil se não houver dados).
-- Defensivo: aceita só a tabela esperada e arredonda a % pra inteiro.
local function TrendText(trend)
  if type(trend) ~= "table" or type(trend.dir) ~= "string" then return nil end
  if trend.dir == "up" then
    return string.format(L.TREND_UP, math.floor((trend.pct or 0) + 0.5))
  elseif trend.dir == "down" then
    return string.format(L.TREND_DOWN, math.floor(math.abs(trend.pct or 0) + 0.5))
  else
    return L.TREND_STABLE
  end
end

local function QueryLinkCommand(link)
  local price = KrononMarket.GetPriceByLink(link)
  if type(price) == "number" and price > 0 then
    local id = C_Item.GetItemInfoInstant(link)
    local info = id and KrononMarket.GetPriceInfo(id)
    local age = (info and info.ageSeconds) or 0
    print(KM_PREFIX .. string.format(L.ASK_PRICE_HAVE, link, Money(price), FormatDuration(age)))
    local tt = TrendText(id and KrononMarket.GetPriceTrend(id))
    if tt then print(KM_PREFIX .. tt) end
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
  elseif cmd == "bar" then
    BarCommand()
  elseif cmd == "help" then
    PrintHelp()
  elseif cmd:match("^%d+$") then
    -- conveniência: /km <itemID>
    local id = tonumber(cmd)
    local info = id and KrononMarket.GetPriceInfo(id)
    if info and info.price then
      print(KM_PREFIX .. string.format(L.ASK_PRICE_HAVE, "item:" .. id, Money(info.price), FormatDuration(info.ageSeconds or 0)))
      local tt = TrendText(KrononMarket.GetPriceTrend(id))
      if tt then print(KM_PREFIX .. tt) end
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
frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
frame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
frame:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
frame:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")

frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    InitDB() -- reino já disponível: inicializa e migra o DB legado
  elseif event == "AUCTION_HOUSE_SHOW" then
    ahOpen = true
    if CanScan() then
      BeginScan()
    end
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"
      or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    -- novo conjunto/lote de resultados: relê o estado completo e pagina.
    ProcessBrowse()
  elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
    FlushThrottled()
  elseif event == "AUCTION_HOUSE_BROWSE_FAILURE"
      or event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    RetryBrowse()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    ahOpen = false
    AbortScan()
  end
end)
