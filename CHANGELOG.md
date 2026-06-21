# Changelog

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
