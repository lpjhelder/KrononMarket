# Changelog

## 0.6.0

**Português**
- **Novo:** **tendência de preço** — ao consultar um item (`/km [link]` ou `/km [itemID]`), o KrononMarket mostra se o preço atual está **acima**, **abaixo** ou **estável** em relação à média recente (ex.: "↑ 12% acima da média").
- **Novo:** API de tendência pros addons consumidores — `GetPriceTrend` e `GetPriceTrendByLink`, lidas sobre o histórico curto já gravado por reino.
- Sem mudanças no preço retornado por `GetPrice` nem no formato salvo — a tendência apenas lê o histórico existente.

**English**
- **New:** **price trend** — when querying an item (`/km [link]` or `/km [itemID]`), KrononMarket shows whether the current price is **above**, **below** or **stable** versus the recent average (e.g. "↑ 12% above average").
- **New:** trend API for consuming addons — `GetPriceTrend` and `GetPriceTrendByLink`, read over the short per-realm history already recorded.
- No changes to the price returned by `GetPrice` nor to the saved format — the trend only reads the existing history.

**Español**
- **Nuevo:** **tendencia de precio** — al consultar un objeto (`/km [enlace]` o `/km [itemID]`), KrononMarket muestra si el precio actual está **por encima**, **por debajo** o **estable** respecto a la media reciente (p. ej. "↑ 12% sobre la media").
- **Nuevo:** API de tendencia para los addons consumidores — `GetPriceTrend` y `GetPriceTrendByLink`, leídas sobre el historial corto ya registrado por reino.
- Sin cambios en el precio que devuelve `GetPrice` ni en el formato guardado — la tendencia solo lee el historial existente.

## 0.5.0

**Português**
- **Melhorado:** o motor de varredura foi reescrito para usar a **busca incremental** da Casa de Leilões (o mesmo método do scan padrão do Auctionator), no lugar da réplica completa antiga.
- **Melhorado:** a varredura **começa quase de imediato** — a barra de progresso ganha vida em 1-2s, com feedback "Consultando a Casa de Leilões…" assim que abre a AH.
- **Melhorado:** **acabou a espera de 15 minutos** entre varreduras imposta pelo método antigo; agora há só um pequeno intervalo (1 min) pra não re-escanear a cada reabertura — e `/km scan` ignora qualquer intervalo.
- **Melhorado:** gear e commodities tratados corretamente — menor preço unitário por item, com a mesma proteção contra preços-isca.

**English**
- **Improved:** the scan engine was rewritten to use the Auction House **incremental browse** (the same method as Auctionator's default scan), replacing the old full replicate.
- **Improved:** scanning **starts almost instantly** — the progress bar comes alive in 1-2s, showing "Querying the Auction House…" as soon as the AH opens.
- **Improved:** **no more 15-minute wait** between scans imposed by the old method; now there is only a short interval (1 min) to avoid rescanning on every reopen — and `/km scan` ignores any interval.
- **Improved:** gear and commodities handled correctly — lowest unit price per item, with the same lowball protection.

**Español**
- **Mejorado:** el motor de escaneo se reescribió para usar la **búsqueda incremental** de la Casa de Subastas (el mismo método del escaneo por defecto de Auctionator), en lugar de la réplica completa anterior.
- **Mejorado:** el escaneo **empieza casi de inmediato** — la barra de progreso cobra vida en 1-2s, mostrando "Consultando la Casa de Subastas…" en cuanto se abre la CS.
- **Mejorado:** **se acabó la espera de 15 minutos** entre escaneos que imponía el método anterior; ahora solo hay un breve intervalo (1 min) para no reescanear en cada reapertura — y `/km scan` ignora cualquier intervalo.
- **Mejorado:** equipo y mercancías se tratan correctamente — precio unitario más bajo por objeto, con la misma protección anti-lowball.

## 0.4.1

**Português**
- **Novo:** **barra de progresso flutuante** durante a varredura da Casa de Leilões — aparece ao iniciar, mostra a porcentagem e some ao terminar.
- **Novo:** a barra é **móvel** (arraste) e a posição fica salva; `/km bar` liga/desliga (ligada por padrão).
- **Novo:** API de progresso pros addons consumidores — `RegisterForProgress` e `GetScanProgress`.

**English**
- **New:** **floating progress bar** during the Auction House scan — shows up on start, displays the percentage and disappears when done.
- **New:** the bar is **movable** (drag) and its position is saved; `/km bar` toggles it (on by default).
- **New:** progress API for consuming addons — `RegisterForProgress` and `GetScanProgress`.

**Español**
- **Nuevo:** **barra de progreso flotante** durante el escaneo de la Casa de Subastas — aparece al iniciar, muestra el porcentaje y desaparece al terminar.
- **Nuevo:** la barra es **movible** (arrastrar) y su posición se guarda; `/km bar` la activa/desactiva (activada por defecto).
- **Nuevo:** API de progreso para los addons consumidores — `RegisterForProgress` y `GetScanProgress`.

## 0.4.0

**Português**
- **Novo:** preços agora são **separados por reino** (não misturam mais reinos); os preços antigos foram migrados pro reino atual sem perder nada.
- **Novo:** preço mais **robusto** — usa a mediana das últimas varreduras em vez de um único menor valor, com proteção contra preços-isca (lowball).
- **Novo:** comandos `/km scan` (força varredura), `/km clear` (apaga os preços do reino, com confirmação), `/km help` e `/km [link do item]` (consulta o preço de um item).
- **Novo:** API `GetPriceInfo` expõe preço, data e idade do preço pros addons consumidores.
- **Melhorado:** uma varredura interrompida no meio **não descarta mais** o que já foi coletado.
- **Melhorado:** entradas com mais de ~30 dias são removidas automaticamente; intervalo entre varreduras agora é configurável.
- **Corrigido:** se faltarem bibliotecas, o addon avisa com clareza e se desativa em vez de gerar erro.

**English**
- **New:** prices are now **kept per realm** (no more mixing realms); existing prices were migrated to the current realm without any loss.
- **New:** more **robust** pricing — uses the median of the last few scans instead of a single lowest value, with lowball protection.
- **New:** commands `/km scan` (force a scan), `/km clear` (erase the realm's prices, with confirmation), `/km help` and `/km [item link]` (query an item's price).
- **New:** `GetPriceInfo` API exposes price, timestamp and price age to consuming addons.
- **Improved:** a scan interrupted midway **no longer discards** what it already collected.
- **Improved:** entries older than ~30 days are pruned automatically; the scan interval is now configurable.
- **Fixed:** if libraries are missing, the addon reports it clearly and disables itself instead of throwing an error.

**Español**
- **Nuevo:** los precios ahora se **guardan por reino** (ya no se mezclan reinos); los precios existentes se migraron al reino actual sin pérdidas.
- **Nuevo:** precio más **robusto** — usa la mediana de los últimos escaneos en vez de un único valor más bajo, con protección anti-lowball.
- **Nuevo:** comandos `/km scan` (fuerza un escaneo), `/km clear` (borra los precios del reino, con confirmación), `/km help` y `/km [enlace de objeto]` (consulta el precio de un objeto).
- **Nuevo:** la API `GetPriceInfo` expone precio, fecha y antigüedad del precio a los addons consumidores.
- **Mejorado:** un escaneo interrumpido a la mitad **ya no descarta** lo que ya recolectó.
- **Mejorado:** las entradas de más de ~30 días se eliminan automáticamente; el intervalo entre escaneos ahora es configurable.
- **Corregido:** si faltan bibliotecas, el addon lo avisa con claridad y se desactiva en vez de generar un error.

## 0.3.0
**Português**
- **Corrigido:** a versão de interface declarada voltou para **12.0.7** (a 12.1.0 anterior foi engano e fazia o addon aparecer como "Incompatível").
- **Novo:** os addons Kronon agora aparecem agrupados sob "Kronon" na lista de addons do jogo.

**English**
- **Fixed:** the declared interface version is back to **12.0.7** (the previous 12.1.0 was a mistake that made the addon show as "Out of date").
- **New:** Kronon addons now appear grouped under "Kronon" in the game's addon list.

**Español**
- **Corregido:** la versión de interfaz declarada volvió a **12.0.7** (la 12.1.0 anterior fue un error que hacía aparecer el addon como "Incompatible").
- **Nuevo:** los addons Kronon ahora aparecen agrupados bajo "Kronon" en la lista de addons del juego.

## 0.2.0

**Português**
- Passa a usar a biblioteca **KrononLib**: i18n e barramento de eventos agora são compartilhados pelo ecossistema Kronon.

**English**
- Now powered by the **KrononLib** library: i18n and the event bus are now shared across the Kronon ecosystem.

**Español**
- Ahora usa la biblioteca **KrononLib**: la i18n y el bus de eventos pasan a ser compartidos por el ecosistema Kronon.

## 0.1.1
**Português**
- Compatível com o patch **12.1.0** (Midnight).

**English**
- Compatible with patch **12.1.0** (Midnight).

**Español**
- Compatible con el parche **12.1.0** (Midnight).

## 0.1.0

**Português**

- **Coletor de preços** da Casa de Leilões: escaneia a AH ao abri-la (a cada 15 min) e guarda o **menor preço por item**.
- **API pra outros addons**: fornece os valores de mercado pro **KrononBags** e quem mais quiser consumir.
- **Comando `/km`**: mostra o status (última varredura, itens no banco, se está escaneando).
- Varredura em lotes pra **não travar o cliente**; aborta limpo se a Casa de Leilões fechar no meio.

**English**

- **Price collector** for the Auction House: scans the AH when you open it (every 15 min) and stores the **lowest price per item**.
- **API for other addons**: provides market values to **KrononBags** and anyone else who wants to consume them.
- **`/km` command**: shows status (last scan, items in database, whether a scan is running).
- Batched scanning so it **won't freeze the client**; aborts cleanly if the Auction House closes mid-scan.

**Español**

- **Recolector de precios** de la Casa de Subastas: escanea la CS al abrirla (cada 15 min) y guarda el **precio más bajo por objeto**.
- **API para otros addons**: provee los valores de mercado a **KrononBags** y a quien quiera consumirlos.
- **Comando `/km`**: muestra el estado (último escaneo, objetos en la base, si hay un escaneo en curso).
- Escaneo por lotes para **no congelar el cliente**; aborta de forma limpia si la Casa de Subastas se cierra a mitad.
