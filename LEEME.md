# KombatBlox

Fighter PvP anime para Roblox. El código vive en este repositorio y se sincroniza con Studio mediante **Rojo**.

## Preparar tu PC (una sola vez)

1. Instala **Git**: https://git-scm.com
2. Instala **Rokit** (en PowerShell):
   ```powershell
   Invoke-RestMethod https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.ps1 | Invoke-Expression
   ```
3. Descarga el proyecto e instala Rojo:
   ```powershell
   git clone https://github.com/DarkSoul8050/KombatBlox.git
   cd KombatBlox
   rokit install
   ```
4. En Roblox Studio: **Plugins → Administrar plugins**, busca **Rojo** e instálalo.

## Trabajar cada día

1. `git pull` para bajar los cambios del compañero.
2. `rojo serve` y, en Studio, **Plugins → Rojo → Connect**.
3. Programa editando los archivos de `src/`, **nunca** los scripts dentro de Studio.
4. Al terminar:
   ```powershell
   git add .
   git commit -m "qué has hecho"
   git push
   ```

## Qué va en cada sitio

| Qué | Dónde |
|---|---|
| Código (scripts) | `src/` en este repo (GitHub) |
| Mapa, modelos, animaciones, VFX | El place de Roblox con **Team Create** |
