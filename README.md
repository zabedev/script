# Guia de Instalação -- Sistema de Aquisição de Dados (Zabe Gateway)

Este documento descreve como instalar, atualizar, remover e reiniciar o
**Zabe Gateway** utilizando o menu interativo do instalador oficial.

------------------------------------------------------------------------

## 1. Executar o Instalador

Para iniciar o processo, execute:

``` bash
curl -s https://raw.githubusercontent.com/zabedev/script/main/install.sh | sudo bash
```

O comando baixa e executa o instalador, que abrirá um menu interativo.

------------------------------------------------------------------------

## 2. Menu Principal

Após iniciar o instalador, o seguinte menu será exibido:

    Zabe Gateway – Manager

    1) Atualizar sistema operacional
    2) Instalar Zabe Gateway
    3) Reiniciar dispositivo
    4) Remover Zabe Gateway
    5) Sair

------------------------------------------------------------------------

## 3. Funções do Menu

### 3.1 Atualizar sistema operacional

Atualiza pacotes e dependências do dispositivo.\
Recomendado antes da instalação ou atualização do Gateway.

### 3.2 Instalar Zabe Gateway

Realiza a instalação completa do sistema de aquisição de dados,
incluindo: - Download dos componentes\
- Configuração de diretórios\
- Criação e ajuste de serviços

Após essa etapa, o sistema estará pronto para operação.

### 3.3 Reiniciar dispositivo

Reinicia o equipamento imediatamente.\
Utilize quando alguma instalação exigir reinicialização.

### 3.4 Remover Zabe Gateway

Remove completamente: - Binários\
- Diretórios do sistema\
- Serviços vinculados

Use para desinstalação total ou reinstalação limpa.

### 3.5 Sair

Fecha o menu e encerra o gerenciador.

------------------------------------------------------------------------

## 4. Finalização

Com este guia, o processo de instalação e gerenciamento do **Zabe
Gateway** fica documentado passo a passo.
