# ALAP 2026 — Fecundidade por Raça/Cor nos Municípios Brasileiros (2022)

Script oficial de replicação para o pôster apresentado na **ALAP 2026** (Associação Latino-Americana de População). O script calcula a Taxa de Fecundidade Total (TFT) desagregada por raça/cor (`branca`, `preta`, `parda`, `amarela` e `indígena`), identifica a raça de maior TFT em cada município (predominância municipal) e mapeia os clusters espaciais de TFT total via estatística LISA (Local Indicators of Spatial Association) com inferência por permutação.

---

## 📌 Características

- **Totalmente reproduzível**: baixa automaticamente os dados da tabela 10078 do SIDRA/IBGE e as malhas municipais/estaduais do pacote `geobr`.
- **Análise substantiva**: 
  - TEF (Taxa Específica de Fecundidade) por idade e raça.
  - ΔTFT (diferença em relação à raça branca) com magnitudes de Cohen.
  - Predominância municipal (raça com maior TFT).
  - LISA analítico (benchmark do paper) e LISA por permutação (principal para o pôster).
- **Figuras prontas para publicação**:
  - Curvas de TEF com redundância visual (cor + linha + símbolo).
  - Densidades de ΔTFT.
  - Mapas coropléticos **rasterizados** (sem bordas municipais) + fronteiras estaduais próprias (`geobr::read_state()`).
  - Formatos: **PNG** (alta resolução) e **PDF** (vetorial), fundo transparente.
- **Auditoria integrada**: compara os resultados com os números do paper aprovado diretamente no console e salva um resumo em CSV.

---

## ⚠️ ATENÇÃO — CONFIGURAÇÃO OBRIGATÓRIA

O script possui um caminho absoluto fixo para o diretório do projeto. **Antes de rodar**, edite a linha **~30** do arquivo `script_tft.R`:

```r
# Altere este caminho para o diretório onde o script está salvo no seu computador
raiz_projeto <- "C:/Users/uriel/Documents/UFPB Estatística/ALAP 2026/fecundidade"
