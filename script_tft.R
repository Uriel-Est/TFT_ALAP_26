# ==============================================================================
# script_tft_poster_v6.R
# ALAP — BRASIL 2022 (MUNICÍPIO)
# TEF por raça/cor + predominância municipal + ΔTFT vs Branca + LISA
# Versão para pôster: figuras em PNG e PDF; mapas sem bordas municipais
#
# PRINCÍPIOS DESTA VERSÃO
#   1) Mantém a lógica substantiva do paper aprovado.
#   2) Remove a ramificação de "padronização BR" do script antigo.
#   3) Calcula o LISA de duas formas:
#        a) analítica, reproduzindo o paper (benchmark);
#        b) permutacional, para a versão do pôster (principal).
#      Também calcula uma sensibilidade BH/FDR, mas NÃO a usa no mapa principal.
#   4) Imprime no console os resultados-chave e compara com os números do paper.
#   5) Figuras: sem título/subtítulo/caption; fundo transparente; PNG + PDF.
#   6) Acessibilidade: cor + tipo de linha + símbolo nos gráficos de curvas.
#   7) Choropleths: as classes municipais são rasterizadas antes do ggplot.
#      Nenhuma borda municipal é desenhada. As fronteiras estaduais vêm de
#      geobr::read_state(), isto é, da malha estadual própria — NÃO de st_union()
#      sobre os municípios. Isso evita que fissuras/topologia municipal apareçam
#      como uma falsa malha preta no mapa final.
# ==============================================================================

rm(list = ls(all.names = TRUE)); gc()

cat("\n")
cat(strrep("=", 94), "\n")
cat("  script_tft_poster_v6.R — Brasil 2022 — início\n")
cat(strrep("=", 94), "\n\n")

# ------------------------------------------------------------------------------
# 0) CONFIGURAÇÃO
# ------------------------------------------------------------------------------
raiz_projeto <- getwd()  # ou
raiz_projeto <- here::here()
stopifnot(dir.exists(raiz_projeto))
setwd(raiz_projeto)

options(timeout = 600)
options(dplyr.summarise.inform = FALSE)
sf::sf_use_s2(FALSE)

PERIOD <- 2022L
AGE5_KEEP <- c("15-19", "20-24", "25-29", "30-34", "35-39", "40-44", "45-49")

RACES_TARGET <- c("branca", "preta", "parda", "indigena", "amarela")
RACE_REF     <- "branca"
RACES_COMP   <- c("amarela", "parda", "indigena", "preta")

# Mesmos limiares do paper/script aprovado
MIN_WOMEN_RACE_MUNI      <- 100L
MIN_WOMEN_AGE5_RACE_MUNI <- 7L

# LISA permutacional
LISA_NSIM  <- 999L
LISA_ALPHA <- 0.05
LISA_SEED  <- 20260811L

# Resolução horizontal da grade usada APENAS nos dois choropleths.
# O mapa final é raster categórico; portanto não há polígonos municipais
# individuais no dispositivo gráfico e não podem aparecer seams entre eles.
MAP_RASTER_NCOL <- 2000L

# Fundo dos DOIS mapas. Mantido transparente, como pedido originalmente.
# Se quiser fundo branco no arquivo final, basta trocar por "white".
MAP_BG <- "transparent"

# ------------------------------------------------------------------------------
# 1) PACOTES
# ------------------------------------------------------------------------------
pkgs <- c(
  "sidrar", "dplyr", "tibble", "tidyr", "stringr", "readr", "arrow",
  "sf", "geobr", "ggplot2", "scales", "openxlsx", "grid", "ggrepel",
  "spdep", "ragg", "terra"
)

to_install <- setdiff(pkgs, rownames(installed.packages()))
if (length(to_install)) install.packages(to_install, dependencies = TRUE)
invisible(lapply(pkgs, require, character.only = TRUE))

# ------------------------------------------------------------------------------
# 2) PASTAS / SAÍDAS
# ------------------------------------------------------------------------------
# Sem acento no nome físico da pasta para evitar problema de encoding no Windows.
BASE_OUTDIR <- file.path(raiz_projeto, "apresentacao")
TIMESTAMP   <- format(Sys.time(), "%Y%m%d_%H%M%S")
RESULTS_DIR <- file.path(BASE_OUTDIR, paste0("run_", TIMESTAMP))

CACHE_DIR <- file.path(raiz_projeto, "_cache_tft")
dir.create(CACHE_DIR, recursive = TRUE, showWarnings = FALSE)

dir_data <- file.path(RESULTS_DIR, "dados")
dir_tab  <- file.path(RESULTS_DIR, "tabelas")
dir_fig  <- file.path(RESULTS_DIR, "figuras")

dir.create(dir_data, recursive = TRUE, showWarnings = FALSE)
dir.create(dir_tab,  recursive = TRUE, showWarnings = FALSE)
dir.create(dir_fig,  recursive = TRUE, showWarnings = FALSE)

RAW_CACHE <- file.path(CACHE_DIR, sprintf("sidra_10078_%s.parquet", PERIOD))

OUT_AGE_PARQUET      <- file.path(dir_data, sprintf("fertility_age_%s.parquet", PERIOD))
OUT_MUNI_PARQUET     <- file.path(dir_data, sprintf("fertility_muni_%s.parquet", PERIOD))
OUT_TOTAL_PARQUET    <- file.path(dir_data, sprintf("fertility_muni_total_%s.parquet", PERIOD))
OUT_EFFECTS_PARQUET  <- file.path(dir_data, sprintf("effects_vs_branca_%s.parquet", PERIOD))
OUT_PRED_PARQUET     <- file.path(dir_data, sprintf("pred_race_%s.parquet", PERIOD))
OUT_LISA_ANALYTIC    <- file.path(dir_data, sprintf("lisa_analitico_paper_%s.parquet", PERIOD))
OUT_LISA_PERM        <- file.path(dir_data, sprintf("lisa_permutacao_%s.parquet", PERIOD))
OUT_XLSX             <- file.path(dir_tab,  sprintf("resultados_poster_%s.xlsx", PERIOD))
OUT_CONSOLE_SUMMARY  <- file.path(dir_tab,  sprintf("benchmarks_paper_%s.csv", PERIOD))

cat("Run: ", normalizePath(RESULTS_DIR, winslash = "/", mustWork = FALSE), "\n", sep = "")
cat("Figuras: ", normalizePath(dir_fig, winslash = "/", mustWork = FALSE), "\n\n", sep = "")

# ------------------------------------------------------------------------------
# 3) ESTILO / ACESSIBILIDADE
# ------------------------------------------------------------------------------
FONT_FAMILY <- "Times New Roman"
TEXT_SIZE   <- 14
TEXT_MM     <- TEXT_SIZE / ggplot2::.pt

NA_FILL <- "#D7CFE6"

# Paleta com boa distinção + redundância por linetype/shape nos gráficos.
# Cor NÃO é o único canal de informação nas curvas.
RACE_COLORS <- c(
  "Branca"   = "#000000",
  "Preta"    = "#E69F00",
  "Parda"    = "#56B4E9",
  "Amarela"  = "#009E73",
  "Indígena" = "#D55E00"
)

RACE_LTY <- c(
  "Branca"   = "solid",
  "Preta"    = "longdash",
  "Parda"    = "dotted",
  "Amarela"  = "dotdash",
  "Indígena" = "twodash"
)

RACE_SHAPES <- c(
  "Branca"   = 16,
  "Preta"    = 17,
  "Parda"    = 15,
  "Amarela"  = 18,
  "Indígena" = 8
)

# Mapa de predominância. Mantemos cores do trabalho, sem textura municipal.
RACE_COLORS_MAP <- c(
  "Branca"   = "#4E79A7",
  "Preta"    = "#E69F00",
  "Parda"    = "#56B4E9",
  "Amarela"  = "#009E73",
  "Indígena" = "#D55E00",
  "Sem base" = NA_FILL
)

# LISA: esquema vermelho/azul clássico, com classes contrastantes.
LISA_COLORS <- c(
  "Alto-Alto"         = "#E31A1C",
  "Baixo-Baixo"       = "#377EB8",
  "Alto-Baixo"        = "#FC8D59",
  "Baixo-Alto"        = "#9ECAE1",
  "Não significativo" = "#D9D9D9",
  "Sem dados"         = NA_FILL
)

theme_poster_base <- function() {
  ggplot2::theme_minimal(base_family = FONT_FAMILY, base_size = TEXT_SIZE) +
    ggplot2::theme(
      text = ggplot2::element_text(family = FONT_FAMILY, size = TEXT_SIZE),

      plot.title    = ggplot2::element_blank(),
      plot.subtitle = ggplot2::element_blank(),
      plot.caption  = ggplot2::element_blank(),

      plot.background       = ggplot2::element_rect(fill = "transparent", color = NA),
      panel.background      = ggplot2::element_rect(fill = "transparent", color = NA),
      legend.background     = ggplot2::element_rect(fill = "transparent", color = NA),
      legend.box.background = ggplot2::element_rect(fill = "transparent", color = NA),
      legend.key            = ggplot2::element_rect(fill = "transparent", color = NA),

      legend.position = "bottom",
      legend.title = ggplot2::element_text(size = TEXT_SIZE, face = "bold"),
      legend.text  = ggplot2::element_text(size = TEXT_SIZE - 1),

      axis.title = ggplot2::element_text(size = TEXT_SIZE),
      axis.text  = ggplot2::element_text(size = TEXT_SIZE - 1, color = "black"),

      panel.grid.major = ggplot2::element_line(color = "grey82", linewidth = 0.35),
      panel.grid.minor = ggplot2::element_blank(),
      panel.border     = ggplot2::element_rect(fill = NA, color = "black", linewidth = 0.55),

      plot.margin = ggplot2::margin(7, 7, 7, 7)
    )
}

theme_poster_map <- function() {
  ggplot2::theme_void(base_family = FONT_FAMILY, base_size = TEXT_SIZE) +
    ggplot2::theme(
      text = ggplot2::element_text(family = FONT_FAMILY, size = TEXT_SIZE),

      plot.title    = ggplot2::element_blank(),
      plot.subtitle = ggplot2::element_blank(),
      plot.caption  = ggplot2::element_blank(),

      plot.background       = ggplot2::element_rect(fill = MAP_BG, color = NA),
      panel.background      = ggplot2::element_rect(fill = MAP_BG, color = NA),
      legend.background     = ggplot2::element_rect(fill = MAP_BG, color = NA),
      legend.box.background = ggplot2::element_rect(fill = MAP_BG, color = NA),
      legend.key            = ggplot2::element_rect(fill = MAP_BG, color = NA),

      legend.position = "bottom",
      legend.title = ggplot2::element_text(size = TEXT_SIZE, face = "bold"),
      legend.text  = ggplot2::element_text(size = TEXT_SIZE - 1),

      plot.margin = ggplot2::margin(3, 3, 3, 3)
    )
}

save_poster_both <- function(plot, stem, width, height, dpi = 450) {
  png_file <- file.path(dir_fig, paste0(stem, ".png"))
  pdf_file <- file.path(dir_fig, paste0(stem, ".pdf"))

  ggplot2::ggsave(
    filename = png_file,
    plot = plot,
    width = width,
    height = height,
    units = "in",
    dpi = dpi,
    bg = "transparent",
    device = ragg::agg_png,
    limitsize = FALSE
  )

  ggplot2::ggsave(
    filename = pdf_file,
    plot = plot,
    width = width,
    height = height,
    units = "in",
    bg = "transparent",
    device = grDevices::cairo_pdf,
    limitsize = FALSE
  )

  cat("  ✓ ", stem, "  [PNG + PDF]\n", sep = "")
}

# Exportador específico dos mapas. O fundo é controlado por MAP_BG.
save_map_both <- function(plot, stem, width, height, dpi = 600) {
  png_file <- file.path(dir_fig, paste0(stem, ".png"))
  pdf_file <- file.path(dir_fig, paste0(stem, ".pdf"))

  ggplot2::ggsave(
    filename = png_file,
    plot = plot,
    width = width,
    height = height,
    units = "in",
    dpi = dpi,
    bg = MAP_BG,
    device = ragg::agg_png,
    limitsize = FALSE
  )

  ggplot2::ggsave(
    filename = pdf_file,
    plot = plot,
    width = width,
    height = height,
    units = "in",
    bg = MAP_BG,
    device = grDevices::cairo_pdf,
    limitsize = FALSE
  )

  cat("  ✓ ", stem, "  [MAPA | PNG + PDF | fundo = ", MAP_BG, "]\n", sep = "")
}

# ------------------------------------------------------------------------------
# 4) HELPERS
# ------------------------------------------------------------------------------
norm_key <- function(x) {
  x <- as.character(x)
  x <- tolower(x)
  x <- suppressWarnings(iconv(x, from = "", to = "ASCII//TRANSLIT", sub = ""))
  x <- gsub("[^a-z0-9]+", " ", x)
  trimws(x)
}

pick_col <- function(nms, patterns, label = "coluna") {
  nms_n <- norm_key(nms)
  hit <- Reduce(`|`, lapply(patterns, function(p) grepl(p, nms_n)))
  idx <- which(hit)
  if (!length(idx)) {
    stop(
      "Não achei ", label,
      " (padrões: ", paste(patterns, collapse = ", "), ").\nColunas: ",
      paste(nms, collapse = " | ")
    )
  }
  nms[idx[1]]
}

chunk_vec <- function(x, size) split(x, ceiling(seq_along(x) / size))

hr <- function(char = "-", n = 94) cat(strrep(char, n), "\n")

# Impressão robusta no console: funciona tanto para data.frame quanto para tibble.
# O argumento n = Inf pertence ao método de impressão de tibble; passá-lo a
# print.data.frame pode gerar o erro "especificação de na.print inválida".
print_all <- function(x) {
  print(tibble::as_tibble(x), n = Inf, width = Inf)
  invisible(x)
}

compare_paper <- function(label, observed, expected, tol = 0) {
  ok <- is.finite(observed) && abs(observed - expected) <= tol
  status <- if (ok) "OK" else "VERIFICAR"
  cat(sprintf(
    "  [%-9s] %-46s observado = %-10.4f | paper = %-10.4f | Δ = %+.4f\n",
    status, label, observed, expected, observed - expected
  ))
  invisible(ok)
}

# Extrai de maneira robusta o p-valor realmente simulado do localmoran_perm().
extract_local_perm_p <- function(x) {
  nms <- colnames(x)
  sim_cols <- nms[grepl("Sim", nms, fixed = TRUE)]
  sim_cols <- sim_cols[!grepl("folded", sim_cols, ignore.case = TRUE)]
  if (!length(sim_cols)) {
    stop(
      "Não encontrei a coluna de p-valor simulado em localmoran_perm(). Colunas: ",
      paste(nms, collapse = " | ")
    )
  }
  as.numeric(x[, sim_cols[1]])
}

classify_lisa <- function(ii, x, p, alpha = 0.05) {
  x_mean <- mean(x, na.rm = TRUE)
  dplyr::case_when(
    is.na(x) | is.na(p)         ~ "Sem dados",
    p >= alpha                  ~ "Não significativo",
    ii > 0 & x >  x_mean        ~ "Alto-Alto",
    ii > 0 & x <= x_mean        ~ "Baixo-Baixo",
    ii < 0 & x >  x_mean        ~ "Alto-Baixo",
    ii < 0 & x <= x_mean        ~ "Baixo-Alto",
    TRUE                        ~ "Não significativo"
  )
}

association_stats <- function(lisa_data, pred_data, cluster_col = "lisa_cluster") {
  z <- lisa_data %>%
    dplyr::select(code_muni7, !!rlang::sym(cluster_col)) %>%
    dplyr::rename(lisa_cluster = !!rlang::sym(cluster_col)) %>%
    dplyr::left_join(pred_data, by = "code_muni7") %>%
    dplyr::mutate(
      pred_label = dplyr::case_when(
        is.na(pred_race)        ~ "Sem base",
        pred_race == "branca"   ~ "Branca",
        pred_race == "preta"    ~ "Preta",
        pred_race == "parda"    ~ "Parda",
        pred_race == "amarela"  ~ "Amarela",
        pred_race == "indigena" ~ "Indígena",
        TRUE                    ~ "Sem base"
      ),
      lisa_cluster = dplyr::if_else(is.na(lisa_cluster), "Sem dados", lisa_cluster),
      is_altoalto  = lisa_cluster == "Alto-Alto",
      is_indigpred = pred_label == "Indígena"
    )

  tab_full <- with(z, table(lisa_cluster, pred_label))
  chi_full <- suppressWarnings(chisq.test(tab_full))

  n_tot <- sum(tab_full)
  k_min <- min(nrow(tab_full) - 1, ncol(tab_full) - 1)
  cramer_v <- if (k_min > 0) sqrt(as.numeric(chi_full$statistic) / (n_tot * k_min)) else NA_real_

  aa_indig_stdres <- NA_real_
  if ("Alto-Alto" %in% rownames(chi_full$stdres) && "Indígena" %in% colnames(chi_full$stdres)) {
    aa_indig_stdres <- unname(chi_full$stdres["Alto-Alto", "Indígena"])
  }

  p_indig_overall  <- mean(z$is_indigpred, na.rm = TRUE)
  p_indig_altoalto <- mean(z$is_indigpred[z$is_altoalto], na.rm = TRUE)
  rr_indig <- p_indig_altoalto / p_indig_overall

  tab_2x2 <- with(z, table(is_altoalto, is_indigpred))
  chi_2x2 <- suppressWarnings(chisq.test(tab_2x2))

  list(
    data = z,
    tab_full = tab_full,
    chi_full = chi_full,
    cramer_v = cramer_v,
    aa_indig_stdres = aa_indig_stdres,
    p_indig_overall = p_indig_overall,
    p_indig_altoalto = p_indig_altoalto,
    rr_indig = rr_indig,
    tab_2x2 = tab_2x2,
    chi_2x2 = chi_2x2
  )
}

# ------------------------------------------------------------------------------
# 4.1) HELPER CARTOGRÁFICO — CHOROPLETH SEM BORDAS MUNICIPAIS
# ------------------------------------------------------------------------------
# Converte uma camada municipal sf categórica em pixels. O ggplot recebe somente
# uma grade raster; nenhuma geometria municipal é desenhada no PNG/PDF.
# Resultado: zero stroke e zero seam entre polígonos.
rasterize_categorical_map <- function(sf_data, class_col, class_levels,
                                      ncol = MAP_RASTER_NCOL) {
  stopifnot(inherits(sf_data, "sf"))
  stopifnot(class_col %in% names(sf_data))

  dat <- sf_data %>%
    dplyr::mutate(
      .map_class = as.character(.data[[class_col]]),
      .map_id = match(.map_class, class_levels)
    )

  if (anyNA(dat$.map_id)) {
    bad <- sort(unique(dat$.map_class[is.na(dat$.map_id)]))
    stop(
      "Classe(s) cartográfica(s) não previstas: ",
      paste(bad, collapse = ", ")
    )
  }

  # Mantém somente o identificador numérico junto da geometria.
  v <- terra::vect(dat[, ".map_id", drop = FALSE])
  e <- terra::ext(v)

  dx <- as.numeric(e$xmax - e$xmin)
  dy <- as.numeric(e$ymax - e$ymin)
  nrow <- max(1L, as.integer(round(ncol * dy / dx)))

  template <- terra::rast(
    e,
    ncols = ncol,
    nrows = nrow,
    crs = terra::crs(v)
  )

  # Cada célula recebe UMA classe. Não há linha, stroke ou antialiasing
  # entre municípios, porque o mapa deixa de ser vetorial neste ponto.
  r <- terra::rasterize(
    v,
    template,
    field = ".map_id",
    background = NA,
    touches = FALSE
  )

  out <- terra::as.data.frame(r, xy = TRUE, na.rm = TRUE)
  names(out)[3] <- ".map_id"

  out$.map_class <- factor(
    class_levels[out$.map_id],
    levels = class_levels
  )

  cat(sprintf(
    "  Raster cartográfico: %d × %d células | %.2f milhões de pixels preenchidos\n",
    terra::ncol(r), terra::nrow(r), nrow(out) / 1e6
  ))

  out
}

# ------------------------------------------------------------------------------
# 5) MALHAS — MUNICÍPIOS PARA ANÁLISE + ESTADOS DE FONTE PRÓPRIA
# ------------------------------------------------------------------------------
cat("===[ 1) Malhas ]===\n")

# IMPORTANTE:
# - muni é usado nos cálculos e na rasterização das classes.
# - states NÃO é construído dissolvendo muni. Ele vem diretamente de read_state().
#   Assim, a única linha preta sobre os choropleths é a fronteira estadual real.

muni_raw <- geobr::read_municipality(
  year = 2020,
  code_muni = "all",
  simplified = TRUE,
  cache = FALSE
)

if (is.null(muni_raw) || !inherits(muni_raw, "sf")) {
  stop("Falha ao obter a malha municipal do geobr.")
}

muni <- muni_raw %>%
  dplyr::mutate(
    code_muni7 = stringr::str_pad(as.character(code_muni), 7, pad = "0")
  ) %>%
  sf::st_make_valid() %>%
  sf::st_transform(5880)

# MALHA ESTADUAL PRÓPRIA — não usar st_union(muni) aqui.
states_raw <- geobr::read_state(
  year = 2020,
  code_state = "all",
  simplified = TRUE,
  cache = FALSE
)

if (is.null(states_raw) || !inherits(states_raw, "sf")) {
  stop("Falha ao obter a malha estadual do geobr.")
}

states <- states_raw %>%
  sf::st_make_valid() %>%
  sf::st_transform(5880)

if (nrow(states) != 27L) {
  warning("A malha estadual retornou ", nrow(states), " feições; esperado: 27.")
}

all_muni_codes <- unique(muni$code_muni7)
cat("Municípios na malha: ", length(all_muni_codes), "\n", sep = "")
cat("Estados/DF na malha estadual própria: ", nrow(states), "\n", sep = "")
cat("Fonte das linhas pretas dos mapas: geobr::read_state() — nenhuma borda municipal.\n\n")

# ------------------------------------------------------------------------------
# 6) SIDRA 10078 — DOWNLOAD / CACHE
# ------------------------------------------------------------------------------
cat("===[ 2) SIDRA 10078 ]===\n")

TBL <- 10078
v_women  <- 13315
v_births <- 13317

cc_age  <- "c12232"
cc_race <- "c12293"
cc_edu  <- "c1568"

age_codes  <- c(104541, 104544, 104545, 104546, 104547, 104548, 104549)
race_codes <- c(105167, 105168, 105170, 105171, 105169)
edu_total  <- 120704

race_map <- c(
  "105167" = "branca",
  "105168" = "preta",
  "105170" = "parda",
  "105171" = "indigena",
  "105169" = "amarela"
)

age_map <- c(
  "104541" = "15-19",
  "104544" = "20-24",
  "104545" = "25-29",
  "104546" = "30-34",
  "104547" = "35-39",
  "104548" = "40-44",
  "104549" = "45-49"
)

CHUNK_SIZE <- 250L

get_chunk_sidra_onevar <- function(muni_codes_chr, var_code, var_key) {
  api <- paste0(
    "/t/", TBL,
    "/n6/", paste(muni_codes_chr, collapse = ","),
    "/v/", var_code,
    "/p/", PERIOD,
    "/", cc_age,  "/", paste(age_codes, collapse = ","),
    "/", cc_race, "/", paste(race_codes, collapse = ","),
    "/", cc_edu,  "/", edu_total,
    "/f/a/h/y/d/s"
  )
  x <- sidrar::get_sidra(api = api)
  x$var_key <- var_key
  x
}

safe_get <- function(munis, var_code, var_key) {
  ok <- FALSE
  tries <- 0L
  while (!ok && tries < 4L) {
    tries <- tries + 1L
    out <- try(get_chunk_sidra_onevar(munis, var_code, var_key), silent = TRUE)
    if (!inherits(out, "try-error") && nrow(out) > 0) {
      ok <- TRUE
    } else {
      Sys.sleep(2)
    }
  }
  if (!ok) stop("Falha definitiva no request var=", var_code, " (", var_key, ")")
  out
}

if (file.exists(RAW_CACHE)) {
  cat("Cache encontrado: ", RAW_CACHE, "\n", sep = "")
  raw <- arrow::read_parquet(RAW_CACHE)
} else {
  chunks <- chunk_vec(all_muni_codes, CHUNK_SIZE)
  cat("Baixando em", length(chunks), "chunks...\n")
  raw_list <- vector("list", length(chunks))

  for (i in seq_along(chunks)) {
    cat(sprintf("  - chunk %02d/%02d | municípios=%d\n", i, length(chunks), length(chunks[[i]])))
    births_i <- safe_get(chunks[[i]], v_births, "births12")
    women_i  <- safe_get(chunks[[i]], v_women,  "women")
    raw_list[[i]] <- dplyr::bind_rows(births_i, women_i)
  }

  raw <- dplyr::bind_rows(raw_list)
  arrow::write_parquet(raw, RAW_CACHE)
  cat("Cache salvo: ", RAW_CACHE, "\n", sep = "")
}

stopifnot(nrow(raw) > 0, "var_key" %in% names(raw))
cat("Linhas SIDRA:", format(nrow(raw), big.mark = "."), "\n\n")

# ------------------------------------------------------------------------------
# 7) LIMPEZA ROBUSTA — MESMA LÓGICA DO SCRIPT ORIGINAL
# ------------------------------------------------------------------------------
cat("===[ 3) Limpeza SIDRA ]===\n")

nms   <- names(raw)
nms_n <- norm_key(nms)

col_muni_code <- pick_col(
  nms,
  c("^municipio \\(codigo\\)$", "municipio.*codigo", "munic.*codigo", "n6.*codigo"),
  "Município (Código)"
)

race_code_cols <- nms[grepl("cor ou raca", nms_n) & grepl("codigo", nms_n)]
race_desc_cols <- nms[grepl("cor ou raca", nms_n) & !grepl("codigo", nms_n)]
col_race_code  <- if (length(race_code_cols)) race_code_cols[1] else NA_character_
col_race_desc  <- if (length(race_desc_cols)) race_desc_cols[1] else NA_character_

age_code_cols <- nms[
  (grepl("grupos de idade", nms_n) | grepl("c12232", nms_n)) &
    grepl("codigo", nms_n) &
    !grepl("unidade de medida", nms_n)
]
age_desc_cols <- nms[
  (grepl("grupos de idade", nms_n) | grepl("c12232", nms_n)) &
    !grepl("codigo", nms_n) &
    !grepl("unidade de medida", nms_n)
]

col_age_code <- if (length(age_code_cols)) age_code_cols[1] else NA_character_
col_age_desc <- if (length(age_desc_cols)) age_desc_cols[1] else NA_character_

col_val <- if ("Valor" %in% nms) {
  "Valor"
} else if ("V" %in% nms) {
  "V"
} else {
  pick_col(nms, c("^valor$", "^v$"), "Valor")
}

if (is.na(col_age_code) || is.na(col_age_desc)) stop("Não consegui identificar colunas de IDADE.")
if (is.na(col_race_code) || is.na(col_race_desc)) stop("Não consegui identificar colunas de RAÇA.")

df <- raw %>%
  dplyr::transmute(
    code_muni7    = stringr::str_pad(as.character(.data[[col_muni_code]]), 7, pad = "0"),
    race_code_raw = as.character(.data[[col_race_code]]),
    race_desc_raw = as.character(.data[[col_race_desc]]),
    age_code_raw  = as.character(.data[[col_age_code]]),
    age_desc_raw  = as.character(.data[[col_age_desc]]),
    var_key       = as.character(.data[["var_key"]]),
    value_raw     = as.character(.data[[col_val]])
  ) %>%
  dplyr::mutate(
    value = dplyr::case_when(
      value_raw %in% c("-", "–") ~ 0,
      TRUE ~ suppressWarnings(readr::parse_number(value_raw))
    ),

    race_key = dplyr::case_when(
      !is.na(race_code_raw) & race_code_raw %in% names(race_map) ~ unname(race_map[race_code_raw]),
      is.na(race_code_raw) & !is.na(race_desc_raw) &
        grepl("^\\d+$", race_desc_raw) & race_desc_raw %in% names(race_map) ~ unname(race_map[race_desc_raw]),
      TRUE ~ {
        rn <- norm_key(race_desc_raw)
        dplyr::case_when(
          stringr::str_detect(rn, "branc")  ~ "branca",
          stringr::str_detect(rn, "pret")   ~ "preta",
          stringr::str_detect(rn, "pard")   ~ "parda",
          stringr::str_detect(rn, "indig")  ~ "indigena",
          stringr::str_detect(rn, "amarel") ~ "amarela",
          TRUE ~ NA_character_
        )
      }
    ),

    age5 = dplyr::case_when(
      !is.na(age_code_raw) & age_code_raw %in% names(age_map) ~ unname(age_map[age_code_raw]),
      is.na(age_code_raw) & !is.na(age_desc_raw) &
        grepl("^\\d+$", age_desc_raw) & age_desc_raw %in% names(age_map) ~ unname(age_map[age_desc_raw]),
      TRUE ~ {
        m <- stringr::str_match(age_desc_raw, "(\\d+)\\D+(\\d+)")
        dplyr::if_else(
          !is.na(m[, 2]) & !is.na(m[, 3]),
          paste0(m[, 2], "-", m[, 3]),
          NA_character_
        )
      }
    )
  ) %>%
  dplyr::filter(
    var_key %in% c("births12", "women"),
    !is.na(race_key),
    !is.na(age5),
    age5 %in% AGE5_KEEP,
    race_key %in% RACES_TARGET
  )

df_wide <- df %>%
  dplyr::group_by(code_muni7, race_key, age5, var_key) %>%
  dplyr::summarise(value = sum(value, na.rm = TRUE), .groups = "drop") %>%
  tidyr::pivot_wider(names_from = var_key, values_from = value) %>%
  dplyr::mutate(
    births12 = tidyr::replace_na(as.numeric(births12), 0),
    women    = tidyr::replace_na(as.numeric(women), 0)
  )

if (!all(c("births12", "women") %in% names(df_wide))) stop("Não gerou births12/women.")
cat("Base limpa: OK\n\n")

# ------------------------------------------------------------------------------
# 8) TAXAS — SEM A RAMIFICAÇÃO DE PADRONIZAÇÃO BR
# ------------------------------------------------------------------------------
cat("===[ 4) TEF / TFT / TFG ]===\n")

df_age <- df_wide %>%
  dplyr::mutate(
    period = PERIOD,
    p_birth = dplyr::if_else(
      women >= MIN_WOMEN_AGE5_RACE_MUNI,
      births12 / women,
      NA_real_
    ),
    tef = 1000 * p_birth
  ) %>%
  dplyr::select(period, code_muni7, race_key, age5, births12, women, p_birth, tef)

df_muni <- df_age %>%
  dplyr::group_by(period, code_muni7, race_key) %>%
  dplyr::summarise(
    births_15_49 = sum(births12, na.rm = TRUE),
    women_15_49  = sum(women, na.rm = TRUE),
    tfg = dplyr::if_else(women_15_49 > 0, 1000 * births_15_49 / women_15_49, NA_real_),
    tft = 5 * sum(p_birth, na.rm = TRUE),
    n_age_valid = sum(!is.na(p_birth)),
    .groups = "drop"
  ) %>%
  dplyr::mutate(
    ok_age_full = n_age_valid == length(AGE5_KEEP),
    ok_sample   = women_15_49 >= MIN_WOMEN_RACE_MUNI & ok_age_full,
    tfg = dplyr::if_else(ok_sample, tfg, NA_real_),
    tft = dplyr::if_else(ok_sample, tft, NA_real_)
  )

# Total municipal: mesma lógica do script original (sem limiar racial)
df_total_age <- df_wide %>%
  dplyr::mutate(period = PERIOD) %>%
  dplyr::group_by(period, code_muni7, age5) %>%
  dplyr::summarise(
    births12 = sum(births12, na.rm = TRUE),
    women    = sum(women, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  dplyr::mutate(
    p_birth   = dplyr::if_else(women > 0, births12 / women, NA_real_),
    tef_total = 1000 * p_birth
  )

df_total_muni <- df_total_age %>%
  dplyr::group_by(period, code_muni7) %>%
  dplyr::summarise(
    tft_total = 5 * sum(p_birth, na.rm = TRUE),
    tfg_total = {
      b <- sum(births12, na.rm = TRUE)
      w <- sum(women, na.rm = TRUE)
      dplyr::if_else(w > 0, 1000 * b / w, NA_real_)
    },
    .groups = "drop"
  )

cat("Taxas calculadas: OK\n\n")

# ------------------------------------------------------------------------------
# 9) ΔTFT E MAGNITUDE VS BRANCA — MESMA REGRA DO PAPER
# ------------------------------------------------------------------------------
cat("===[ 5) ΔTFT vs Branca ]===\n")

sd_nacional_branca <- df_muni %>%
  dplyr::filter(race_key == RACE_REF) %>%
  dplyr::pull(tft) %>%
  stats::sd(na.rm = TRUE)

cohen_limits <- c(
  "desprezivel" = 0.2 * sd_nacional_branca,
  "pequena"     = 0.5 * sd_nacional_branca,
  "media"       = 0.8 * sd_nacional_branca
)

ref <- df_muni %>%
  dplyr::filter(race_key == RACE_REF) %>%
  dplyr::select(period, code_muni7, tft_ref = tft)

effects_vs_branca <- df_muni %>%
  dplyr::filter(race_key %in% RACES_COMP) %>%
  dplyr::left_join(ref, by = c("period", "code_muni7")) %>%
  dplyr::mutate(
    delta_tft = tft - tft_ref,
    magnitude = dplyr::case_when(
      is.na(delta_tft) ~ NA_character_,
      abs(delta_tft) < cohen_limits["desprezivel"] ~ "Desprezível",
      abs(delta_tft) < cohen_limits["pequena"]     ~ "Pequena",
      abs(delta_tft) < cohen_limits["media"]       ~ "Média",
      TRUE ~ "Grande"
    ),
    magnitude = factor(magnitude, levels = c("Desprezível", "Pequena", "Média", "Grande")),
    race_comp = race_key,
    race_ref  = RACE_REF
  ) %>%
  dplyr::select(period, code_muni7, race_ref, race_comp, tft_ref, tft, delta_tft, magnitude)

cat(sprintf("DP municipal da TFT Branca = %.4f\n", sd_nacional_branca))
cat(sprintf(
  "Limiares |ΔTFT|: 0,2σ = %.4f | 0,5σ = %.4f | 0,8σ = %.4f\n\n",
  cohen_limits["desprezivel"],
  cohen_limits["pequena"],
  cohen_limits["media"]
))

# ------------------------------------------------------------------------------
# 10) PREDOMINÂNCIA MUNICIPAL — MANTIDA COMO NO PAPER
# ------------------------------------------------------------------------------
cat("===[ 6) Raça/cor com maior TFT no município ]===\n")

pred_race <- df_muni %>%
  dplyr::filter(!is.na(tft)) %>%
  dplyr::group_by(code_muni7) %>%
  dplyr::slice_max(order_by = tft, n = 1, with_ties = FALSE) %>%
  dplyr::ungroup() %>%
  dplyr::select(code_muni7, pred_race = race_key)

cat("Predominância calculada: OK\n\n")

# ------------------------------------------------------------------------------
# 11) LISA — ANALÍTICO (PAPER) + PERMUTAÇÃO (PÔSTER)
# ------------------------------------------------------------------------------
cat("===[ 7) LISA: benchmark analítico + versão permutacional ]===\n")

muni_lisa <- muni %>%
  dplyr::left_join(
    df_total_muni %>% dplyr::select(code_muni7, tft_total),
    by = "code_muni7"
  )

# Em princípio a TFT total deve existir para todos; o subset abaixo torna o código robusto.
muni_lisa_valid <- muni_lisa %>% dplyr::filter(!is.na(tft_total))

if (nrow(muni_lisa_valid) != nrow(muni_lisa)) {
  cat("ATENÇÃO: ", nrow(muni_lisa) - nrow(muni_lisa_valid),
      " município(s) sem TFT total; serão excluídos do LISA.\n", sep = "")
}

nb_valid <- spdep::poly2nb(muni_lisa_valid, queen = TRUE)
listw_valid <- spdep::nb2listw(nb_valid, style = "W", zero.policy = TRUE)

x_lisa <- muni_lisa_valid$tft_total

# 11.1 Analítico — reproduz o procedimento do paper/script antigo
local_analytic <- spdep::localmoran(
  x_lisa,
  listw_valid,
  zero.policy = TRUE,
  na.action = na.fail,
  alternative = "two.sided"
)

p_analytic <- as.numeric(local_analytic[, "Pr(z != E(Ii))"])

lisa_analytic_valid <- tibble::tibble(
  code_muni7 = muni_lisa_valid$code_muni7,
  tft_total  = x_lisa,
  ii         = as.numeric(local_analytic[, "Ii"]),
  eii        = as.numeric(local_analytic[, "E.Ii"]),
  var_ii     = as.numeric(local_analytic[, "Var.Ii"]),
  z_ii       = as.numeric(local_analytic[, "Z.Ii"]),
  p_analytic = p_analytic
) %>%
  dplyr::mutate(
    lisa_cluster_analytic = classify_lisa(ii, tft_total, p_analytic, LISA_ALPHA)
  )

lisa_analytic <- muni %>%
  sf::st_drop_geometry() %>%
  dplyr::select(code_muni7) %>%
  dplyr::left_join(lisa_analytic_valid, by = "code_muni7") %>%
  dplyr::mutate(
    lisa_cluster_analytic = dplyr::if_else(
      is.na(lisa_cluster_analytic), "Sem dados", lisa_cluster_analytic
    )
  )

# 11.2 Permutacional — versão principal do pôster
set.seed(LISA_SEED)
local_perm <- spdep::localmoran_perm(
  x_lisa,
  listw_valid,
  nsim = LISA_NSIM,
  zero.policy = TRUE,
  na.action = na.fail,
  alternative = "two.sided",
  iseed = LISA_SEED
)

p_perm <- extract_local_perm_p(local_perm)
p_perm_fdr <- stats::p.adjust(p_perm, method = "BH")

lisa_perm_valid <- tibble::tibble(
  code_muni7 = muni_lisa_valid$code_muni7,
  tft_total  = x_lisa,
  ii         = as.numeric(local_perm[, "Ii"]),
  eii        = as.numeric(local_perm[, "E.Ii"]),
  var_ii     = as.numeric(local_perm[, "Var.Ii"]),
  z_ii       = as.numeric(local_perm[, "Z.Ii"]),
  p_perm     = p_perm,
  p_perm_fdr = p_perm_fdr
) %>%
  dplyr::mutate(
    lisa_cluster_perm = classify_lisa(ii, tft_total, p_perm, LISA_ALPHA),
    lisa_cluster_fdr  = classify_lisa(ii, tft_total, p_perm_fdr, LISA_ALPHA)
  )

lisa_perm <- muni %>%
  sf::st_drop_geometry() %>%
  dplyr::select(code_muni7) %>%
  dplyr::left_join(lisa_perm_valid, by = "code_muni7") %>%
  dplyr::mutate(
    lisa_cluster_perm = dplyr::if_else(is.na(lisa_cluster_perm), "Sem dados", lisa_cluster_perm),
    lisa_cluster_fdr  = dplyr::if_else(is.na(lisa_cluster_fdr),  "Sem dados", lisa_cluster_fdr)
  )

# Moran global por permutação — diagnóstico adicional
set.seed(LISA_SEED)
moran_global_mc <- spdep::moran.mc(
  x_lisa,
  listw_valid,
  nsim = LISA_NSIM,
  zero.policy = TRUE,
  alternative = "greater"
)

# Associações com predominância
assoc_analytic <- association_stats(lisa_analytic, pred_race, "lisa_cluster_analytic")
assoc_perm     <- association_stats(lisa_perm,     pred_race, "lisa_cluster_perm")
assoc_fdr      <- association_stats(lisa_perm,     pred_race, "lisa_cluster_fdr")

cat("LISA calculado: OK\n\n")

# ------------------------------------------------------------------------------
# 12) AUDITORIA / BENCHMARKS DO PAPER — IMPRESSÃO NO CONSOLE
# ------------------------------------------------------------------------------
cat("\n")
hr("=")
cat("  AUDITORIA DOS RESULTADOS — COMPARAÇÃO COM O PAPER APROVADO\n")
hr("=")

# 12.1 TEF / calendários
cat("\n[1] TEF — picos por raça/cor\n")
hr()

race_levels <- c("branca", "preta", "parda", "amarela", "indigena")
race_labs <- c(
  "branca"   = "Branca",
  "preta"    = "Preta",
  "parda"    = "Parda",
  "amarela"  = "Amarela",
  "indigena" = "Indígena"
)

br_race_age <- df_age %>%
  dplyr::group_by(race_key, age5) %>%
  dplyr::summarise(
    births = sum(births12, na.rm = TRUE),
    women  = sum(women, na.rm = TRUE),
    tef_br = dplyr::if_else(women > 0, 1000 * births / women, NA_real_),
    .groups = "drop"
  ) %>%
  dplyr::mutate(
    age5 = factor(age5, levels = AGE5_KEEP),
    race_label = factor(race_labs[race_key], levels = unname(race_labs[race_levels]))
  )

peaks <- br_race_age %>%
  dplyr::group_by(race_label) %>%
  dplyr::slice_max(order_by = tef_br, n = 1, with_ties = FALSE) %>%
  dplyr::ungroup() %>%
  dplyr::select(race_label, age5, tef_br)

print_all(peaks)

cat("\nTEF aos 15–19 anos (útil para conferir a narrativa do paper):\n")
print_all(
  br_race_age %>%
    dplyr::filter(age5 == "15-19") %>%
    dplyr::select(race_label, tef_br)
)

# 12.2 Predominância
cat("\n[2] Predominância municipal\n")
hr()

pred_summary <- muni %>%
  sf::st_drop_geometry() %>%
  dplyr::select(code_muni7) %>%
  dplyr::left_join(pred_race, by = "code_muni7") %>%
  dplyr::mutate(
    pred_label = dplyr::case_when(
      pred_race == "branca"   ~ "Branca",
      pred_race == "preta"    ~ "Preta",
      pred_race == "parda"    ~ "Parda",
      pred_race == "amarela"  ~ "Amarela",
      pred_race == "indigena" ~ "Indígena",
      TRUE                    ~ "Sem base"
    )
  ) %>%
  dplyr::count(pred_label, name = "n") %>%
  dplyr::mutate(pct = 100 * n / nrow(muni)) %>%
  dplyr::arrange(dplyr::desc(n))

print_all(pred_summary)

paper_pred <- c(
  "Parda"    = 2498,
  "Branca"   = 1513,
  "Preta"    = 1321,
  "Indígena" = 198,
  "Amarela"  = 33
)

cat("\nComparação das contagens com o paper:\n")
for (nm in names(paper_pred)) {
  obs <- pred_summary$n[pred_summary$pred_label == nm]
  if (!length(obs)) obs <- 0
  compare_paper(paste0("Predominância — ", nm, " (n)"), obs, paper_pred[[nm]], tol = 0)
}

# 12.2.1 Diagnóstico da discrepância Amarela (35 no run atual vs 33 no paper)
cat("\n[2A] Diagnóstico dos municípios com predominância Amarela\n")
hr()

# Reproduz literalmente a lógica do script antigo, sem o filter(!is.na(tft)),
# para verificar se a mudança de regra explica alguma classificação.
pred_race_oldlogic <- df_muni %>%
  dplyr::group_by(code_muni7) %>%
  dplyr::slice_max(order_by = tft, n = 1, with_ties = FALSE) %>%
  dplyr::ungroup() %>%
  dplyr::select(code_muni7, pred_oldlogic = race_key, tft_oldlogic = tft)

pred_rule_compare <- muni %>%
  sf::st_drop_geometry() %>%
  dplyr::select(code_muni7, dplyr::any_of(c("name_muni", "abbrev_state"))) %>%
  dplyr::left_join(pred_race_oldlogic, by = "code_muni7") %>%
  dplyr::left_join(pred_race, by = "code_muni7") %>%
  dplyr::mutate(
    mudou_regra = dplyr::case_when(
      is.na(pred_oldlogic) & is.na(pred_race) ~ FALSE,
      xor(is.na(pred_oldlogic), is.na(pred_race)) ~ TRUE,
      TRUE ~ pred_oldlogic != pred_race
    )
  )

cat(sprintf(
  "Diferenças entre lógica antiga e lógica atual de predominância: %d município(s).\n",
  sum(pred_rule_compare$mudou_regra, na.rm = TRUE)
))
if (any(pred_rule_compare$mudou_regra, na.rm = TRUE)) {
  print_all(pred_rule_compare %>% dplyr::filter(mudou_regra))
}

# Ranking 1º/2º lugar para medir quão robusta é a classificação municipal.
tft_ranked <- df_muni %>%
  dplyr::filter(!is.na(tft)) %>%
  dplyr::group_by(code_muni7) %>%
  dplyr::arrange(dplyr::desc(tft), race_key, .by_group = TRUE) %>%
  dplyr::mutate(rank_tft = dplyr::row_number()) %>%
  dplyr::ungroup()

top2_wide <- tft_ranked %>%
  dplyr::filter(rank_tft <= 2) %>%
  dplyr::select(code_muni7, rank_tft, race_key, tft) %>%
  tidyr::pivot_wider(
    names_from = rank_tft,
    values_from = c(race_key, tft),
    names_glue = "{.value}_{rank_tft}"
  )

amarela_age_diag <- df_age %>%
  dplyr::filter(race_key == "amarela") %>%
  dplyr::group_by(code_muni7) %>%
  dplyr::summarise(
    min_women_age_amarela = min(women, na.rm = TRUE),
    n_age_below_7_amarela = sum(women < MIN_WOMEN_AGE5_RACE_MUNI, na.rm = TRUE),
    .groups = "drop"
  )

amarela_muni_diag <- df_muni %>%
  dplyr::filter(race_key == "amarela") %>%
  dplyr::select(code_muni7, women_amarela_15_49 = women_15_49, n_age_valid_amarela = n_age_valid)

muni_lookup <- muni %>%
  sf::st_drop_geometry() %>%
  dplyr::select(code_muni7, dplyr::any_of(c("name_muni", "abbrev_state")))

yellow_diag <- pred_race %>%
  dplyr::filter(pred_race == "amarela") %>%
  dplyr::left_join(muni_lookup, by = "code_muni7") %>%
  dplyr::left_join(top2_wide, by = "code_muni7") %>%
  dplyr::left_join(amarela_muni_diag, by = "code_muni7") %>%
  dplyr::left_join(amarela_age_diag, by = "code_muni7") %>%
  dplyr::mutate(
    margem_tft_1_2 = tft_1 - tft_2,
    empate_exato = !is.na(margem_tft_1_2) & abs(margem_tft_1_2) < 1e-12,
    margem_menor_005 = !is.na(margem_tft_1_2) & margem_tft_1_2 < 0.05
  ) %>%
  dplyr::arrange(margem_tft_1_2, women_amarela_15_49)

cat("\nTodos os municípios classificados como Amarela, ordenados pela menor margem sobre o 2º lugar:\n")
print_all(yellow_diag)

cat(sprintf(
  "\nEmpates exatos entre 1º e 2º lugar entre os Amarela: %d\n",
  sum(yellow_diag$empate_exato, na.rm = TRUE)
))
cat(sprintf(
  "Municípios Amarela com margem < 0,05 filho: %d\n",
  sum(yellow_diag$margem_menor_005, na.rm = TRUE)
))

# Municípios sem qualquer TFT racial válida.
valid_race_count <- df_muni %>%
  dplyr::group_by(code_muni7) %>%
  dplyr::summarise(n_racas_tft_validas = sum(!is.na(tft)), .groups = "drop")

sem_base_diag <- muni_lookup %>%
  dplyr::left_join(valid_race_count, by = "code_muni7") %>%
  dplyr::left_join(pred_race, by = "code_muni7") %>%
  dplyr::filter(is.na(pred_race))

cat("\nMunicípios atualmente classificados como Sem base:\n")
print_all(sem_base_diag)

readr::write_csv(yellow_diag, file.path(dir_tab, sprintf("diagnostico_predominancia_amarela_%s.csv", PERIOD)))
readr::write_csv(sem_base_diag, file.path(dir_tab, sprintf("diagnostico_sem_base_%s.csv", PERIOD)))
readr::write_csv(pred_rule_compare, file.path(dir_tab, sprintf("comparacao_regra_predominancia_%s.csv", PERIOD)))

# 12.3 ΔTFT
cat("\n[3] ΔTFT em relação à Branca\n")
hr()

delta_summary <- effects_vs_branca %>%
  dplyr::filter(!is.na(delta_tft)) %>%
  dplyr::mutate(
    race_label = dplyr::recode(
      race_comp,
      "amarela" = "Amarela",
      "parda" = "Parda",
      "indigena" = "Indígena",
      "preta" = "Preta"
    )
  ) %>%
  dplyr::group_by(race_label) %>%
  dplyr::summarise(
    n_valid = dplyr::n(),
    media = mean(delta_tft),
    mediana = stats::median(delta_tft),
    pct_grande_abs = 100 * mean(magnitude == "Grande"),
    pct_grande_positiva = 100 * mean(delta_tft >= cohen_limits["media"]),
    .groups = "drop"
  )

print_all(delta_summary)

cat("\nComparação dos números citados no paper:\n")
get_delta <- function(race, col) delta_summary[[col]][delta_summary$race_label == race]

compare_paper("Indígena — ΔTFT médio", get_delta("Indígena", "media"), 1.21, tol = 0.02)
compare_paper("Indígena — % magnitude Grande", get_delta("Indígena", "pct_grande_abs"), 80.7, tol = 0.15)
compare_paper("Preta — ΔTFT médio", get_delta("Preta", "media"), 0.30, tol = 0.02)
compare_paper("Preta — % magnitude Grande", get_delta("Preta", "pct_grande_abs"), 62.2, tol = 0.15)
compare_paper("Parda — ΔTFT médio", get_delta("Parda", "media"), 0.31, tol = 0.02)
compare_paper("Parda — % magnitude Grande", get_delta("Parda", "pct_grande_abs"), 51.9, tol = 0.15)
compare_paper("Amarela — ΔTFT médio", get_delta("Amarela", "media"), -0.037, tol = 0.02)
compare_paper("Amarela — mediana ΔTFT", get_delta("Amarela", "mediana"), -0.312, tol = 0.02)
compare_paper("Amarela — % magnitude Grande", get_delta("Amarela", "pct_grande_abs"), 64.1, tol = 0.15)

# 12.4 LISA — benchmark analítico
cat("\n[4] LISA — reprodução analítica do paper\n")
hr()

analytic_counts <- lisa_analytic %>%
  dplyr::count(lisa_cluster_analytic, name = "n") %>%
  dplyr::mutate(pct = 100 * n / nrow(muni)) %>%
  dplyr::arrange(dplyr::desc(n))
print_all(analytic_counts)

n_aa_analytic <- sum(lisa_analytic$lisa_cluster_analytic == "Alto-Alto", na.rm = TRUE)
pct_aa_analytic <- 100 * n_aa_analytic / nrow(muni)

cat("\nBenchmarks espaciais do paper:\n")
compare_paper("LISA analítico — municípios Alto-Alto", n_aa_analytic, 333, tol = 0)
compare_paper("LISA analítico — % Alto-Alto", pct_aa_analytic, 5.98, tol = 0.03)
compare_paper("LISA analítico — V de Cramér", assoc_analytic$cramer_v, 0.157, tol = 0.005)
compare_paper("LISA analítico — resíduo padronizado AA×Indígena", assoc_analytic$aa_indig_stdres, 24.5, tol = 0.5)
cat(sprintf(
  "  Razão calculada diretamente P(Indígena | AA) / P(Indígena | geral) = %.4f\n",
  assoc_analytic$rr_indig
))
cat("  OBS.: o paper registra 11,4×, mas esse valor não é usado como benchmark aqui;\n")
cat("        a seção de arqueologia abaixo testa também métricas baseadas em vizinhança.\n")

cat(sprintf(
  "  Qui-quadrado da associação completa: X² = %.3f | p = %.6g\n",
  as.numeric(assoc_analytic$chi_full$statistic), assoc_analytic$chi_full$p.value
))

# 12.5 LISA por permutação
cat("\n[5] LISA — versão por permutação (principal do pôster)\n")
hr()

perm_counts <- lisa_perm %>%
  dplyr::count(lisa_cluster_perm, name = "n") %>%
  dplyr::mutate(pct = 100 * n / nrow(muni)) %>%
  dplyr::arrange(dplyr::desc(n))
print_all(perm_counts)

n_aa_perm  <- sum(lisa_perm$lisa_cluster_perm == "Alto-Alto", na.rm = TRUE)
pct_aa_perm <- 100 * n_aa_perm / nrow(muni)

cat(sprintf("\nMoran global por permutação: I = %.6f | pseudo-p = %.6g | nsim = %d\n",
            as.numeric(moran_global_mc$statistic), moran_global_mc$p.value, LISA_NSIM))
cat(sprintf("Alto-Alto por permutação: n = %d | %.2f%%\n", n_aa_perm, pct_aa_perm))
cat(sprintf("V de Cramér (perm): %.4f\n", assoc_perm$cramer_v))
cat(sprintf("Resíduo padronizado AA×Indígena (perm): %.2f\n", assoc_perm$aa_indig_stdres))
cat(sprintf("Razão Indígena AA/Geral (perm): %.2f\n", assoc_perm$rr_indig))

# 12.5.1 Arqueologia do 11,4× — testa a hipótese antiga de vizinhança
cat("\n[5A] Arqueologia do 11,4× — predominância Indígena própria ou na vizinhança\n")
hr()

nb_all <- spdep::poly2nb(muni, queen = TRUE)
pred_aligned <- muni %>%
  sf::st_drop_geometry() %>%
  dplyr::select(code_muni7) %>%
  dplyr::left_join(pred_race, by = "code_muni7")

is_indig <- pred_aligned$pred_race == "indigena"
is_indig[is.na(is_indig)] <- FALSE

has_indig_neighbor <- vapply(
  seq_along(nb_all),
  function(i) {
    viz <- nb_all[[i]]
    length(viz) > 0 && any(is_indig[viz], na.rm = TRUE)
  },
  logical(1)
)

arch_114 <- lisa_analytic %>%
  dplyr::select(code_muni7, lisa_cluster_analytic) %>%
  dplyr::left_join(pred_aligned, by = "code_muni7") %>%
  dplyr::mutate(
    indig_proprio = is_indig,
    vizinho_indig = has_indig_neighbor,
    indig_ou_vizinho = indig_proprio | vizinho_indig,
    aa = lisa_cluster_analytic == "Alto-Alto",
    alto_local = lisa_cluster_analytic %in% c("Alto-Alto", "Alto-Baixo")
  )

calc_arch_metric <- function(flag_high, label_high) {
  high <- arch_114[[flag_high]]
  exposure <- arch_114$indig_ou_vizinho

  p_exp_high <- mean(exposure[high], na.rm = TRUE)
  p_exp_all  <- mean(exposure, na.rm = TRUE)
  enrich_exp <- p_exp_high / p_exp_all

  p_high_exp <- mean(high[exposure], na.rm = TRUE)
  p_high_all <- mean(high, na.rm = TRUE)
  enrich_high <- p_high_exp / p_high_all

  tibble::tibble(
    definicao_alto = label_high,
    p_indig_ou_vizinho_dado_alto = p_exp_high,
    p_indig_ou_vizinho_geral = p_exp_all,
    razao_exposicao_alto_geral = enrich_exp,
    p_alto_dado_indig_ou_vizinho = p_high_exp,
    p_alto_geral = p_high_all,
    razao_alto_exposto_geral = enrich_high
  )
}

arch_metrics <- dplyr::bind_rows(
  calc_arch_metric("aa", "Alto-Alto"),
  calc_arch_metric("alto_local", "Alto-Alto + Alto-Baixo")
)

print_all(arch_metrics)
cat("\nSe algum desses quocientes ficar próximo de 11,4, teremos uma pista forte da origem do número antigo.\n")
readr::write_csv(arch_metrics, file.path(dir_tab, sprintf("arqueologia_11_4_%s.csv", PERIOD)))

# Comparação direta das classificações
lisa_compare <- lisa_analytic %>%
  dplyr::select(code_muni7, lisa_cluster_analytic) %>%
  dplyr::left_join(
    lisa_perm %>% dplyr::select(code_muni7, lisa_cluster_perm, lisa_cluster_fdr),
    by = "code_muni7"
  ) %>%
  dplyr::mutate(
    mudou_perm = lisa_cluster_analytic != lisa_cluster_perm,
    mudou_fdr  = lisa_cluster_analytic != lisa_cluster_fdr
  )

cat("\nTabela cruzada: LISA do paper × LISA por permutação\n")
print(with(lisa_compare, table(lisa_cluster_analytic, lisa_cluster_perm)))

cat(sprintf(
  "\nMunicípios que mudaram de classe (analítico → permutação): %d de %d (%.2f%%)\n",
  sum(lisa_compare$mudou_perm, na.rm = TRUE),
  nrow(lisa_compare),
  100 * mean(lisa_compare$mudou_perm, na.rm = TRUE)
))

# FDR como sensibilidade, NÃO como figura principal
cat("\n[6] Sensibilidade adicional — permutação + BH/FDR (não usada no mapa principal)\n")
hr()
fdr_counts <- lisa_perm %>%
  dplyr::count(lisa_cluster_fdr, name = "n") %>%
  dplyr::mutate(pct = 100 * n / nrow(muni)) %>%
  dplyr::arrange(dplyr::desc(n))
print_all(fdr_counts)
cat(sprintf("Razão Indígena AA/Geral (FDR): %.2f\n", assoc_fdr$rr_indig))

hr("=")
cat("  FIM DA AUDITORIA\n")
hr("=")
cat("\n")

# ------------------------------------------------------------------------------
# 13) SALVAR DADOS / TABELAS
# ------------------------------------------------------------------------------
cat("===[ 8) Salvando dados e tabelas ]===\n")

arrow::write_parquet(df_age,            OUT_AGE_PARQUET)
arrow::write_parquet(df_muni,           OUT_MUNI_PARQUET)
arrow::write_parquet(df_total_muni,     OUT_TOTAL_PARQUET)
arrow::write_parquet(effects_vs_branca, OUT_EFFECTS_PARQUET)
arrow::write_parquet(pred_race,         OUT_PRED_PARQUET)
arrow::write_parquet(lisa_analytic,     OUT_LISA_ANALYTIC)
arrow::write_parquet(lisa_perm,         OUT_LISA_PERM)

benchmarks_out <- tibble::tibble(
  indicador = c(
    "sd_tft_branca",
    "limiar_02sigma",
    "limiar_05sigma",
    "limiar_08sigma",
    "pred_parda_n",
    "pred_branca_n",
    "pred_preta_n",
    "pred_indigena_n",
    "pred_amarela_n",
    "lisa_analitico_altoalto_n",
    "lisa_analitico_altoalto_pct",
    "lisa_analitico_cramer_v",
    "lisa_analitico_stdres_aa_indigena",
    "lisa_analitico_rr_indigena",
    "lisa_perm_altoalto_n",
    "lisa_perm_altoalto_pct",
    "lisa_perm_cramer_v",
    "lisa_perm_stdres_aa_indigena",
    "lisa_perm_rr_indigena",
    "moran_global_perm_I",
    "moran_global_perm_p"
  ),
  valor = c(
    sd_nacional_branca,
    cohen_limits["desprezivel"],
    cohen_limits["pequena"],
    cohen_limits["media"],
    pred_summary$n[pred_summary$pred_label == "Parda"],
    pred_summary$n[pred_summary$pred_label == "Branca"],
    pred_summary$n[pred_summary$pred_label == "Preta"],
    pred_summary$n[pred_summary$pred_label == "Indígena"],
    pred_summary$n[pred_summary$pred_label == "Amarela"],
    n_aa_analytic,
    pct_aa_analytic,
    assoc_analytic$cramer_v,
    assoc_analytic$aa_indig_stdres,
    assoc_analytic$rr_indig,
    n_aa_perm,
    pct_aa_perm,
    assoc_perm$cramer_v,
    assoc_perm$aa_indig_stdres,
    assoc_perm$rr_indig,
    as.numeric(moran_global_mc$statistic),
    moran_global_mc$p.value
  )
)
readr::write_csv(benchmarks_out, OUT_CONSOLE_SUMMARY)

wb <- openxlsx::createWorkbook()
for (sheet in c(
  "age_tef", "muni_race", "muni_total", "effects_vs_branca", "pred_race",
  "lisa_analytic", "lisa_perm", "pred_summary", "delta_summary",
  "lisa_compare", "benchmarks"
)) openxlsx::addWorksheet(wb, sheet)

openxlsx::writeDataTable(wb, "age_tef", df_age)
openxlsx::writeDataTable(wb, "muni_race", df_muni)
openxlsx::writeDataTable(wb, "muni_total", df_total_muni)
openxlsx::writeDataTable(wb, "effects_vs_branca", effects_vs_branca)
openxlsx::writeDataTable(wb, "pred_race", pred_race)
openxlsx::writeDataTable(wb, "lisa_analytic", lisa_analytic)
openxlsx::writeDataTable(wb, "lisa_perm", lisa_perm)
openxlsx::writeDataTable(wb, "pred_summary", pred_summary)
openxlsx::writeDataTable(wb, "delta_summary", delta_summary)
openxlsx::writeDataTable(wb, "lisa_compare", lisa_compare)
openxlsx::writeDataTable(wb, "benchmarks", benchmarks_out)
openxlsx::saveWorkbook(wb, OUT_XLSX, overwrite = TRUE)

cat("Dados/tabelas salvos: OK\n\n")

# ------------------------------------------------------------------------------
# 14) FIGURA 1 — CURVAS DE TEF
#     Correção principal: legenda mostra LINHA + SÍMBOLO + COR;
#     geom_label_repel não entra na legenda (remove o 'a' da caixinha).
# ------------------------------------------------------------------------------
cat("===[ 9) Figura 1 — TEF ]===\n")

peaks_plot <- br_race_age %>%
  dplyr::group_by(race_label) %>%
  dplyr::slice_max(order_by = tef_br, n = 1, with_ties = FALSE) %>%
  dplyr::ungroup() %>%
  dplyr::mutate(lbl = sprintf("%.1f", tef_br))

legend_races <- c("Branca", "Preta", "Parda", "Amarela", "Indígena")

p_tef <- ggplot2::ggplot(
  br_race_age,
  ggplot2::aes(
    x = age5,
    y = tef_br,
    color = race_label,
    linetype = race_label,
    shape = race_label,
    group = race_label
  )
) +
  ggplot2::geom_line(linewidth = 1.25) +
  ggplot2::geom_point(size = 2.8, stroke = 0.5) +
  ggrepel::geom_label_repel(
    data = peaks_plot,
    ggplot2::aes(label = lbl),
    family = FONT_FAMILY,
    size = TEXT_MM * 0.92,
    label.size = 0.22,
    min.segment.length = 0,
    box.padding = 0.30,
    point.padding = 0.16,
    fill = "white",
    alpha = 0.97,
    seed = 123,
    show.legend = FALSE
  ) +
  ggplot2::scale_color_manual(
    values = RACE_COLORS,
    breaks = legend_races,
    name = "Raça/cor"
  ) +
  ggplot2::scale_linetype_manual(
    values = RACE_LTY,
    breaks = legend_races,
    name = "Raça/cor"
  ) +
  ggplot2::scale_shape_manual(
    values = RACE_SHAPES,
    breaks = legend_races,
    name = "Raça/cor"
  ) +
  ggplot2::labs(
    x = "Idade (quinquênios)",
    y = "TEF (por 1.000)"
  ) +
  theme_poster_base() +
  ggplot2::theme(
    legend.key.width = grid::unit(1.30, "cm"),
    legend.spacing.x = grid::unit(0.20, "cm")
  )

save_poster_both(
  p_tef,
  sprintf("fig1_tef_idade_raca_%s", PERIOD),
  width = 9.3,
  height = 5.8
)

# ------------------------------------------------------------------------------
# 15) FIGURA 2 — CHOROPLETH DE PREDOMINÂNCIA
#     MAPA RASTER + FRONTEIRA ESTADUAL DIRETA: ZERO BORDAS MUNICIPAIS.
# ------------------------------------------------------------------------------
cat("===[ 10) Figura 2 — Predominância municipal ]===\n")

pred_levels <- c("Branca", "Preta", "Parda", "Amarela", "Indígena", "Sem base")

pred_map_sf <- muni %>%
  dplyr::left_join(pred_race, by = "code_muni7") %>%
  dplyr::mutate(
    pred_label = dplyr::case_when(
      is.na(pred_race)        ~ "Sem base",
      pred_race == "branca"   ~ "Branca",
      pred_race == "preta"    ~ "Preta",
      pred_race == "parda"    ~ "Parda",
      pred_race == "amarela"  ~ "Amarela",
      pred_race == "indigena" ~ "Indígena",
      TRUE                     ~ "Sem base"
    ),
    pred_label = factor(pred_label, levels = pred_levels)
  )

cat("Rasterizando predominância; fronteiras virão somente da malha estadual própria...\n")
pred_raster_df <- rasterize_categorical_map(
  sf_data = pred_map_sf,
  class_col = "pred_label",
  class_levels = pred_levels
)

p_pred <- ggplot2::ggplot(
  pred_raster_df,
  ggplot2::aes(x = x, y = y, fill = .map_class)
) +
  # Um único raster. Nenhum município é desenhado como polígono.
  ggplot2::geom_raster(interpolate = FALSE) +
  # Única fronteira administrativa desenhada: UF.
  ggplot2::geom_sf(
    data = states,
    fill = NA,
    color = "black",
    linewidth = 0.30,
    inherit.aes = FALSE
  ) +
  ggplot2::scale_fill_manual(
    values = RACE_COLORS_MAP,
    breaks = pred_levels,
    drop = FALSE,
    name = "Maior TFT"
  ) +
  ggplot2::guides(
    fill = ggplot2::guide_legend(nrow = 2, byrow = TRUE)
  ) +
  theme_poster_map() +
  ggplot2::coord_sf(
    crs = sf::st_crs(muni),
    default_crs = sf::st_crs(muni),
    expand = FALSE,
    datum = NA
  )

save_map_both(
  p_pred,
  sprintf("fig2_predominancia_tft_municipio_%s", PERIOD),
  width = 8.4,
  height = 7.2,
  dpi = 600
)

# libera memória antes do próximo mapa pesado
rm(pred_raster_df, p_pred)
gc(verbose = FALSE)

# ------------------------------------------------------------------------------
# 16) FIGURA 3 — DENSIDADE DE ΔTFT
#     Correção: cor voltou; também usa linetype diferente por grupo.
#     Fill é suave e não cria uma segunda legenda.
# ------------------------------------------------------------------------------
cat("===[ 11) Figura 3 — Densidade ΔTFT ]===\n")

dens_df <- effects_vs_branca %>%
  dplyr::filter(!is.na(delta_tft)) %>%
  dplyr::mutate(
    race_comp = dplyr::recode(
      race_comp,
      "amarela"  = "Amarela",
      "parda"    = "Parda",
      "indigena" = "Indígena",
      "preta"    = "Preta"
    ),
    race_comp = factor(race_comp, levels = c("Amarela", "Parda", "Indígena", "Preta"))
  )

dens_levels <- c("Amarela", "Parda", "Indígena", "Preta")
dens_cols <- RACE_COLORS[dens_levels]
dens_lty  <- RACE_LTY[dens_levels]

delta_lim <- stats::quantile(abs(dens_df$delta_tft), 0.95, na.rm = TRUE)

p_dens <- ggplot2::ggplot(
  dens_df,
  ggplot2::aes(
    x = delta_tft,
    color = race_comp,
    fill = race_comp,
    linetype = race_comp,
    group = race_comp
  )
) +
  ggplot2::geom_density(
    linewidth = 1.20,
    alpha = 0.12,
    adjust = 1.1
  ) +
  ggplot2::geom_vline(
    xintercept = 0,
    linewidth = 0.70,
    color = "grey35"
  ) +
  ggplot2::geom_vline(
    xintercept = c(-cohen_limits["desprezivel"], cohen_limits["desprezivel"]),
    linetype = "dotted",
    linewidth = 0.50,
    color = "grey48"
  ) +
  ggplot2::geom_vline(
    xintercept = c(-cohen_limits["pequena"], cohen_limits["pequena"]),
    linetype = "dashed",
    linewidth = 0.50,
    color = "grey48"
  ) +
  ggplot2::geom_vline(
    xintercept = c(-cohen_limits["media"], cohen_limits["media"]),
    linetype = "longdash",
    linewidth = 0.50,
    color = "grey48"
  ) +
  ggplot2::coord_cartesian(xlim = c(-delta_lim, delta_lim)) +
  ggplot2::scale_color_manual(
    values = dens_cols,
    breaks = dens_levels,
    name = "Raça/cor"
  ) +
  ggplot2::scale_fill_manual(
    values = dens_cols,
    breaks = dens_levels,
    guide = "none"
  ) +
  ggplot2::scale_linetype_manual(
    values = dens_lty,
    breaks = dens_levels,
    name = "Raça/cor"
  ) +
  ggplot2::labs(
    x = "ΔTFT em relação à Branca (filhos por mulher)",
    y = "Densidade"
  ) +
  theme_poster_base() +
  ggplot2::theme(
    legend.key.width = grid::unit(1.35, "cm"),
    legend.spacing.x = grid::unit(0.20, "cm")
  )

save_poster_both(
  p_dens,
  sprintf("fig3_densidade_delta_tft_%s", PERIOD),
  width = 9.3,
  height = 5.8
)

# ------------------------------------------------------------------------------
# 17) FIGURA 4 — LISA POR PERMUTAÇÃO
#     MAPA RASTER + FRONTEIRA ESTADUAL DIRETA: ZERO BORDAS MUNICIPAIS.
# ------------------------------------------------------------------------------
cat("===[ 12) Figura 4 — LISA permutacional ]===\n")

lisa_levels <- c(
  "Alto-Alto", "Baixo-Baixo", "Alto-Baixo", "Baixo-Alto",
  "Não significativo", "Sem dados"
)

muni_lisa_plot <- muni %>%
  dplyr::left_join(
    lisa_perm %>% dplyr::select(code_muni7, lisa_cluster_perm),
    by = "code_muni7"
  ) %>%
  dplyr::mutate(
    lisa_cluster_perm = dplyr::if_else(
      is.na(lisa_cluster_perm), "Sem dados", lisa_cluster_perm
    ),
    lisa_cluster_perm = factor(
      lisa_cluster_perm,
      levels = lisa_levels
    )
  )

cat("Clusters que entrarão no mapa LISA:\n")
print_all(
  muni_lisa_plot %>%
    sf::st_drop_geometry() %>%
    dplyr::count(lisa_cluster_perm, name = "n") %>%
    dplyr::arrange(dplyr::desc(n))
)

cat("Rasterizando LISA; fronteiras virão somente da malha estadual própria...\n")
lisa_raster_df <- rasterize_categorical_map(
  sf_data = muni_lisa_plot,
  class_col = "lisa_cluster_perm",
  class_levels = lisa_levels
)

p_lisa <- ggplot2::ggplot(
  lisa_raster_df,
  ggplot2::aes(x = x, y = y, fill = .map_class)
) +
  ggplot2::geom_raster(interpolate = FALSE) +
  ggplot2::geom_sf(
    data = states,
    fill = NA,
    color = "black",
    linewidth = 0.30,
    inherit.aes = FALSE
  ) +
  ggplot2::scale_fill_manual(
    values = LISA_COLORS,
    breaks = lisa_levels,
    drop = FALSE,
    name = "Cluster LISA"
  ) +
  ggplot2::guides(
    fill = ggplot2::guide_legend(nrow = 2, byrow = TRUE)
  ) +
  theme_poster_map() +
  ggplot2::coord_sf(
    crs = sf::st_crs(muni),
    default_crs = sf::st_crs(muni),
    expand = FALSE,
    datum = NA
  )

save_map_both(
  p_lisa,
  sprintf("fig4_lisa_tft_total_permutacao_%s", PERIOD),
  width = 8.4,
  height = 7.2,
  dpi = 600
)

rm(lisa_raster_df, p_lisa)
gc(verbose = FALSE)

# ------------------------------------------------------------------------------
# 18) RESUMO FINAL
# ------------------------------------------------------------------------------
cat("\n")
hr("=")
cat("  CONCLUÍDO\n")
hr("=")
cat("Pasta da run: ", normalizePath(RESULTS_DIR, winslash = "/", mustWork = FALSE), "\n", sep = "")
cat("Figuras:      ", normalizePath(dir_fig, winslash = "/", mustWork = FALSE), "\n", sep = "")
cat("Tabelas:      ", normalizePath(dir_tab, winslash = "/", mustWork = FALSE), "\n", sep = "")
cat("\nIMPORTANTE:\n")
cat("  • Fig. 4 usa LISA por permutação (p_sim < 0,05).\n")
cat("  • A reprodução analítica do paper foi mantida apenas como benchmark no console/dados.\n")
cat("  • A versão BH/FDR é uma sensibilidade adicional e NÃO entra no mapa principal.\n")
cat("  • Os choropleths são rasterizados e recebem apenas a malha estadual de geobr::read_state().\n")
cat("  • Não há st_union(muni) para construir fronteiras estaduais e não há stroke municipal.\n")
cat("  • Se os itens marcados [VERIFICAR] aparecerem na auditoria do paper, não feche o pôster\n")
cat("    antes de entender a divergência.\n")
hr("=")
