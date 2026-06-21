# KrononMarket

Coletor de preços da Casa de Leilões para o ecossistema **Kronon**. Escaneia a AH e disponibiliza os valores de mercado pra outros addons — principalmente o **KrononBags**.

## O que é

Um addon leve, sem interface própria, cujo único trabalho é varrer a Casa de Leilões e manter um banco de preços por item. Esses preços ficam acessíveis via API pra qualquer addon do ecossistema mostrar valor de mercado real.

## Como funciona

1. Você abre a **Casa de Leilões**.
2. O KrononMarket escaneia automaticamente (no máximo a cada **15 minutos**), guardando o **menor preço unitário** (buyout / quantidade) de cada item.
3. O **KrononBags** (ou outro consumidor) lê esses valores e exibe o preço de mercado.

A varredura roda em **lotes** pra não travar o cliente e é **abortada com segurança** se você fechar a AH no meio — nesse caso o banco não é sobrescrito e uma nova tentativa fica liberada na próxima abertura.

## Comando

- `/km` (ou `/kmarket`): mostra o status — quando foi a última varredura, quantos itens há no banco e se um scan está em andamento.

## API (pra desenvolvedores)

```lua
KrononMarket.GetPrice(itemID)            -- menor buyout unitário (cobre) ou nil
KrononMarket.GetPriceByLink(itemLink)    -- idem, a partir de um link de item
KrononMarket.GetLastScan()               -- epoch da última varredura ou nil
KrononMarket.IsScanning()                -- true se há varredura em andamento
KrononMarket.RegisterForUpdate(callback) -- chamado ao fim de cada varredura
```

## Ecossistema

Parte do **Kronon**. Funciona sozinho, mas brilha junto com o [KrononBags](https://github.com/).
