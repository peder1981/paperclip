#INCLUDE "Rwmake.ch"
#INCLUDE "Protheus.ch"
#INCLUDE "Topconn.ch"
#INCLUDE "Sigawin.ch"
#INCLUDE "Tbiconn.ch"
#INCLUDE "Fileio.ch"

/***************************************************************************
* Programa....: ORTA023D                                                   *
* Autor.......: E.L.O.                                                     *
* Finalidade..: Importação dos Resumos de Vendas de Cartões.               *
* Data........: 07/12/06                                                   *
***************************************************************************/
/***************************************************************************
* Alteracao:  21.11.12  - Decio                                            *
*             inclusao da rotina de gravacao dos cartoes CREDISHOP         *
*             11.04.12  - DECIO                                            *
*             ajustes na rotina cielo()identificacao correta da bandeira   *
*             16.04.12  - DECIO                                            *
*             melhorar as mensagens de erro no log (canout)                *
*             03.07.13  - MARCOS FURTADO                                   *
*             Correção de importação do arquivo quando é a bandeira e      *
*             BANESE. A rotina não estava considerando o tipo de pgto do   *
*             arquivo para importar somente quando é informado todas as    *
*             parcelas. 												   *
* Henrique - 15/10/2013 - SSI 31879                                        *
*            Em levantamento com o Decio, observamos que as linhas corretas*
*            para valicação deveriam ser a que estavam inibidas  e  nao  as*
*            linhas que foram incluidas. Inibi as linhas incluidas e retor-*
*            as linhas anteriores                                          *
* Henrique - 15/10/2013(A) - SSI 31879                                     *
*            Incluido tratamento para cartao CIELO,  conforme  entendimento*
*            com o Decio, incluimos o tratamento para  evitar  que  valores*
*            zerados fossem gravados quando se tratar de compra no rotativo*
* Henrique - 25/10/2013 - SSI 31879                                        *
*            Incluida linha para incluid 01 na parcela do  cartao  rotativo*
*            da operadora CIELO                                       	     *
* Henrique - 06/11/2013 - SSI 31890                                        *
*            Incluido na variavel "cCodAut" o codigo NSU (Posicao 93,6)  do*
*            arquivo compondo o numero do PV com 12 caracteres.            *
* Henrique - 09/01/2014 - SSI 31895                                        *
*            Incluido a informacao de cancelamento conforme documentado  na*
*            SSI.                                                          *
* Adriano  - 26/07/2018 - Admin. BLU                                       *
*            Incluido a administradora BLU para importação.                *
* Joni	   - 06/11/2019 - Admin. BLU                                       *
*            Pequeno ajuste na gravação do campo PA7_PV do cartão Blu.     *
* Vagner   - 24/11/2020 - Admin. STONE                                     *
*            Incluido a administradora STONE para importação.              *
* Peder    - 17/09/2026 - Admin. CREDISHOP                                 *
*            Tratamento dos arquivos CREDISHOP do tipo "PAG" (extrato de   *
*            pagamento efetuado, resumos na faixa 2xxxxxxx), alem dos ja   *
*            tratados do tipo "PRE" (previsao, resumos faixa 1xxxxxxx).    *
*            Detalhes na funcao Credishop().                               *
***************************************************************************/

// Function ORTA023D
// Verifica os arquivos TXT disponiveis no diretório constante no parametro MV_XPATHCR
// e dispara a funcao relativa a cada operadora.

/*
STATUS DO ARQUIVO SZF
=====================================================================================================
A - ITEM EM ABERTO
B - TITULO BAIXADO
C - TITULO AGUARDANDO BAIXA (APOS RECEBER ARQ. DE BAIXA DA VISA, PREPARA PARA BAIXA DA OUTRA ROTINA)
=====================================================================================================
*/

User Function ORTA023D(nTipo)

	Local u		:= 0

	Private cFile,cFileDest,cFileElet,cFileErro,cAdmin,cPv,cId,cBanco,cAgencia,cConta,cResumo,cNumcart,cCodAut,cParcela,cTotParc,cTipo,nLeErro,_cTpAj
	Private cDescric,cBuffer,cBuffer2,nReg,nArqPro,cTela,nTamFile,nBtLidos,nTamLin,nTotComp
	Private dDataven,dDatapg,dData,nValliq1,nValbrut1,nValtx1,nValtx2,nValliq,nValbrut,nValRej,nValtx,nTotTx,nPerc,nVlparc
	Private cCampo01,cCampo02,cCampo03,cCampo04,cCampo05,cCampo06,cCampo07,cCampo08,cCampo09,cCampo10,cCampo11
	Private cCampo12,cCampo13,cCampo14,cCampo15,cCampo16,cCampo17,cCampo18,cCampo19,cCampo20,cCampo21,cCampo22,cTpPag
	Private vParc
	Private vVettxt
	Private aLogErro
	Private nLinLidas
	Private nErros
	Private _cDirFiles
	Private _cDirLido
	Private _cDirErro
	Private _cDirElet
	Private _aDirectory
	Private _aEmp := {}
	Private _cEmpZF := "  "
	Private _cFilZF := "  "
	Private aRegPa7:= {}
	Private cAdmOri:= ""
	Private cNoPOS := "" //[BRUNO:29/11/2010 - Pegar numero de POS(maquineta)
	Private cArqProc:= ""
	Private cQuery := ""

	If !LockByName("ORTA023D", .F., .F., .F.)
		U_JobCInfo("ORTA023D.PRW", "AMBIENTE:"+upper(alltrim(GetEnvServer()))+" - PROGRAMA JA SE ENCONTRA EM EXECUCAO", 2)
		Return
	EndIf

	BEGIN SEQUENCE

		Conout("ORTA023D - Inicio - AMBIENTE:"+upper(alltrim(GetEnvServer()))+" - "+DTOS(DDATABASE))

		If nTipo == Nil

			_cDirFiles := "\cobol\cobol\regrj\msiga\"        	//GetMV("MV_XPATHCR")
			_cDirLido  := "\cobol\cobol\regrj\msiga\lido\"   	//GetMV("MV_XPATHCL")
			_cDirErro  := "\cobol\cobol\regrj\msiga\erro\"   	//GetMV("MV_XPATHCE")
			_cDirElet  := "\cobol\cobol\regrj\msiga\eletrosom\" //GetMV("MV_XPATHCL")

		Else

			_cDirFiles := Alltrim("C:\Ortobom\cartao\")        //GetMV("MV_XPATHCR")
			_cDirLido  := Alltrim("C:\Ortobom\cartao\Lido\")   //GetMV("MV_XPATHCL")
			_cDirErro  := Alltrim("C:\Ortobom\cartao\Erro\")   //GetMV("MV_XPATHCE")

		EndIf

		vParc := {"1","2","3","4","5","6","7","8","9","A","B","C","D","E","F","G","H","I","J","L","M","N","O","P","Q","R","S","T","U","V","X","Z"}
		vVettxt		:= {}
		aLogErro	:= {}
		nLinLidas	:= 1
		nErros		:= 0

		_aDirectory := DIRECTORY(_cDirFiles+"*.*","S")
		nReg := 0 // zera quantidade de registros processados
		nArqPro := 0

		Conout("ORTA023D - Inicio - AMBIENTE:"+upper(alltrim(GetEnvServer()))+" - "+DTOS(DDATABASE)+" ARQUIVOS A SEREM PROCESSADOS: "+alltrim(str(Len( _aDirectory ))))
		U_JobCInfo("ORTA023D.PRW", "AMBIENTE:"+upper(alltrim(GetEnvServer()))+" - ARQUIVOS A SEREM PROCESSADOS: "+alltrim(str(Len( _aDirectory ))), 2)

		For u:=1 to Len( _aDirectory )

			If AllTrim(UPPER(_aDirectory[u,1])) == "MINUSCULO.SH"
				Loop
			EndIf

			// Limite de 5MB por arquivo (direção do operador): ignorar e logar
			If _aDirectory[u][2] > 5242880
				U_JobCInfo("ORTA023D.PRW", "arquivo ignorado por exceder 5MB: '" + AllTrim(_aDirectory[u][1]) + "' (" + cValToChar(_aDirectory[u][2]) + " bytes)", 1)
				Loop
			EndIf

			nReg := 0
			nArqPro ++

			cFile     := Alltrim(_cDirFiles+_aDirectory[u][1])
			cFileDest := Alltrim(_cDirLido +_aDirectory[u][1])
			cFileElet := Alltrim(_cDirElet +_aDirectory[u][1])
			cFileErro := Alltrim(_cDirErro +_aDirectory[u][1])

			cArqProc  := Alltrim(_aDirectory[u][1])

			LocFun()

			aRegPA7:= {}

		Next

	END SEQUENCE

	Conout("ORTA023D - Fim - "+DTOS(DDATABASE))

	UnLockByName("ORTA023D", .F., .F., .F.)

Return()

Static Function _ORTA023k()

	Private cFile,cFileDest,cFileElet,cFileErro,cAdmin,cPv,cId,cBanco,cAgencia,cConta,cResumo,cNumcart,cCodAut,cParcela,cTotParc,cTipo,nLeErro,_cTpAj
	Private cDescric,cBuffer,cBuffer2,nReg,nArqPro,cTela,nTamFile,nBtLidos,nTamLin,nTotComp
	Private dDataven,dDatapg,dData,nValliq1,nValbrut1,nValtx1,nValtx2,nValliq,nValbrut,nValRej,nValtx,nTotTx,nPerc,nVlparc
	Private cCampo01,cCampo02,cCampo03,cCampo04,cCampo05,cCampo06,cCampo07,cCampo08,cCampo09,cCampo10,cCampo11
	Private cCampo12,cCampo13,cCampo14,cCampo15,cCampo16,cCampo17,cCampo18,cCampo19,cCampo20,cCampo21,cCampo22,cTpPag
	Private vParc
	Private vVettxt
	Private aLogErro
	Private nLinLidas
	Private nErros
	Private _cDirFiles
	Private _cDirLido
	Private _cDirErro
	Private _cDirElet
	Private _aDirectory
	Private _aEmp := {}
	Private _cEmpZF := "  "
	Private _cFilZF := "  "
	Private aRegPa7:= {}
	Private cAdmOri:= ""
	Private cNoPOS := "" //[BRUNO:29/11/2010 - Pegar numero de POS(maquineta)
	Private cArqProc:= ""
	Private cQuery := ""

	BEGIN SEQUENCE

		Conout("ORTA023D - Inicio - AMBIENTE:"+upper(alltrim(GetEnvServer()))+" - "+DTOS(DDATABASE))

		vParc := {"1","2","3","4","5","6","7","8","9","A","B","C","D","E","F","G","H","I","J","L","M","N","O","P","Q","R","S","T","U","V","X","Z"}
		vVettxt		:= {}
		aLogErro	:= {}
		nErros		:= 0
		nReg := 0 // zera quantidade de registros processados

		BLU()

	END SEQUENCE

	Conout("ORTA023D - Fim - "+DTOS(DDATABASE))

Return()

/**************************************************************************
* Programa....: LocFun                                                    *
* Autor.......: Rafael Melo                                               *
* Finalidade..: Escolha da Função de acordo com o Layout do Cartão.       *
* Data........: 22/02/06                                                  *
**************************************************************************/

Static Function LocFun()

	Local nHandle
	Private cEOL  := "CHR(13)+CHR(10)" // CRIA VARIAVEL DE FIM DE LINHA
	U_JobCInfo("ORTA023D.PRW", "LocFun iniciado - arquivo "+cFile, 2)
	cBuffer := ""

	If Empty(cEOL)
		cEOL := CHR(13)+CHR(10)
	Else
		cEOL := Trim(cEOL)
		cEOL := &cEOL
	Endif

	// EEVC/EEVD: anteriormente descartados aqui (return()).
	// Agora processados pelo RedeCard() que ja suporta registros 004/006/008/010/012.
	// EEFI (Extrato Financeiro V4.00): registros 030/032/034/035/037/040/045/050
	// tambem processados pelo RedeCard() com handlers especificos.

	If (nHandle := FT_FUse( cFile )) == -1

		Conout("ORTA023D - O arquivo "+Alltrim(cFile)+" nao pode ser aberto! - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Falha ao abrir o arquivo '"+AllTrim(cFile)+"'", 1)
		Return()

	Endif

	FT_FGOTOP()

	//Peder Munksgaard - 11/07/2018
	//Correção do problema de codepage que ocorria devido a
	//palavra comissão.
	//cBuffer := AllTrim(FT_FREADLN())
	cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
	//
	//alert(cBuffer)
	//alert(Substr(cBuffer,43,05))

	If Substr(cBuffer,1,3) == "00," .And. (",Redecard," $ cBuffer .Or. "EEVD" $ upper(cBuffer))	// EEVD CSV (RD)
		Conout("ORTA023D - Processando RedeCard EEVD - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando RedeCard EEVD (CSV) - "+cFile+" - "+DTOS(DDATABASE), 2)
		EEVD()
	ElseIf Substr(cBuffer,46,07) == "VISANET" .and. Substr(cBuffer,53,1) == "D"  //Escolha do Cartão VISA
		Conout("ORTA023D - Processando Visa - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando Visa - "+cFile+" - "+DTOS(DDATABASE), 2)
		Visa()
	ElseIf upper(Substr(cBuffer,72,08)) == "REDECARD"  //Escolha do Cartão REDSHOP
		Conout("ORTA023D - Processando RedeShop - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando RedeShop - "+cFile+" - "+DTOS(DDATABASE), 2)
		RedShop()
	ElseIf upper(Substr(cBuffer,43,05)) == "CIELO"  //Escolha do Cartão CIELO / DJUAN 02 - 12/03/13
		Conout("ORTA023D - Processando cielo - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando Cielo - "+cFile+" - "+DTOS(DDATABASE), 2)
		Cielo()
	ElseIf Substr(cBuffer,1,3) == "00," .And. (",Redecard," $ cBuffer .Or. "EEVD" $ upper(cBuffer))	// EEVD CSV (RD)
		Conout("ORTA023D - Processando RedeCard EEVD - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando RedeCard EEVD (CSV) - "+cFile+" - "+DTOS(DDATABASE), 2)
		RedeCard()
	ElseIf upper(Substr(cBuffer,12,08)) == "REDECARD"  //Escolha do Cartão REDECARD
		Conout("ORTA023D - Processando RedeCard - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando RedeCard - "+cFile+" - "+DTOS(DDATABASE), 2)
		RedeCard()
	ElseIf upper(Substr(cBuffer,43,09)) == "HIPERCARD"  //Escolha do Cartão HIPERCARD
		Conout("ORTA023D - Processando HiperCard - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando HiperCard - "+cFile+" - "+DTOS(DDATABASE), 2)
		HiperCard()
	ElseIf upper(Substr(cBuffer,61,11)) == "BANESE CARD"  //Escolha do Cartão BANESE
		Conout("ORTA023D - Processando Banese - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando Banese - "+cFile+" - "+DTOS(DDATABASE), 2)
		Banese()
		//Início SSI 12359
	ElseIf upper(Substr(cBuffer,73,08)) == "BANRISUL" .And. upper(Substr(cBuffer,43,05)) <> "BJRVC"  //Escolha do Cartão BANRISUL
		Conout("ORTA023D - Processando Banrisul - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando Banrisul - "+cFile+" - "+DTOS(DDATABASE), 2)
		Banrisul()
		//Fim SSI 12359
	ElseIf upper(Substr(cBuffer,73,04)) == "VERO" .Or. upper(Substr(cBuffer,43,05)) == "BJRVC"  //Escolha do Cartao VERO (BJR02/BJR06/BJR08); ids BJRVC* tem BANRISUL ou VERO na pos. 073
		Conout("ORTA023D - Processando Vero - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando Vero - "+cFile+" - "+DTOS(DDATABASE), 2)
		Vero()
	ElseIf "AMEX" $ cBuffer //.and. ("NEW" $ cBuffer .OR. "REC" $ cBuffer)//Escolha do Cartão AMERICAN EXPRESS
		//ElseIf "EPA FILE HEADER" $ cBuffer .and. ("NEW" $ cBuffer .OR. "REC" $ cBuffer)//Escolha do Cartão AMERICAN EXPRESS
		Conout("ORTA023D - Processando Amex - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando Amex - "+cFile+" - "+DTOS(DDATABASE), 2)
		Amex()
	ElseIf upper(Substr(cBuffer,43,09)) == "CREDISHOP"  //Escolha do Cartao CREDISHOP
		Conout("ORTA023D - Processando Credishop - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando Credishop - "+cFile+" - "+DTOS(DDATABASE), 2)
		Credishop()
	ElseIf upper(Substr(cBuffer,35,08)) == "BANESTES"  //Escolha do Cartao CREDISHOP
		Conout("ORTA023D - Processando Banescard - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando Banescard - "+cFile+" - "+DTOS(DDATABASE), 2)
		BANESCARD()
	ElseIf CredLay341(cBuffer)  //Escolha do Cartao CREDISHOP layout 3.4.1
		Conout("ORTA023D - Processando Credishop 3.4.1 - "+cFile+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "Processando Credishop 3.4.1 - "+cFile+" - "+DTOS(DDATABASE), 2)
		Credishop()
	Else
		Conout("ORTA023D - arquivo invalido - "+cFileErro+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "arquivo invalido - "+cFileErro+" - "+DTOS(DDATABASE), 2)
		JMPcp(cFile,cFileErro)
		Ferase(cFile)
		Return()
	EndIf

	if nLeErro < 10
		// Copia do arquivo para um diretório de bakup definido no parâmetro MV_XDIRCCO
		JMPcp(cFile,cFileDest)
	else
		Conout("ORTA023D - erros acima de 10 - "+cFileErro+" - "+DTOS(DDATABASE))
		U_JobCInfo("ORTA023D.PRW", "erros acima de 10 - "+cFileErro+" - "+DTOS(DDATABASE), 2)
		// Copia do arquivo para sum diretório de erro definido no parâmetro MV_XDIRCCO
		JMPcp(cFile,cFileErro)
	endif

	//copia os arquivos da RedeCard para ser avaliado pela rotina ORTP076 - Marcos Furtado.
	//"\cobol\cobol\regrj\msiga\eletrosom\"

	If !Empty(cFileElet) .and. ("EEVC" $ cFileElet .Or. "EEVD" $ cFileElet)
		JMPcp(cFile,cFileElet)
		cFileElet := ""
	EndIf

	//[BRUNO:24/11/2010] INSERIR EM NOVA TABELA.
	fGeraPA7()

	// Apaga fisicamente arquivo da pasta de origem após ser copiado.
	if fVerGrv(cArqProc,cAdmin)
		Ferase(cFile)
	endif


Return()

/**************************************************************************
* Programa....: RedShop                                                   *
* Finalidade..: Leiltura do arquivo txt dos cartões de Débito RedShop para*
* ............: a alimentação da tabela de Movimento de Cartões.          *
* Data........: 06/03/06                                                  *
**************************************************************************/
Static Function RedShop()
	Private _cBand := "REDECARD"

	//Reinicia Variáveis
	_cEmpZF  := "  "
	_cFilZF  := "  "
	cAdmin   := "19"
	cResumo  := ""
	cCartao  := ""
	cCodAut  := ""
	cParcela := "  "
	cTotParc := "  "
	cDescric := ""
	cTipo    := ""
	dDataven := ""
	dDatapg  := ""
	cId      := ""
	cPv      := ""
	nValliq  := 0
	nValbrut := 0
	nValtx   := 0
	vVettxt  := {}
	nLeErro  := 0
	cAdmOri	 := ""
	cNoPOS   := ""
	/********************************
* Criacao de Tabela temporaria. *
	********************************/

	/*
aAdd(vVettxt,{"CAMPOS","C",500,0})

cArqvettxt := CriaTrab(vVettxt, .T.)
dbUseArea(.T.,,cArqvettxt,"TXT",.F.)
dbSelectArea("TXT")
Append From (cFile) SDF

dbGoTop()

//          1         2         3         4         5         6         7         8         9         0         1         2         3         4
// 12345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890
// 00,013466828,04092007,03092007,Movimentacao diaria - Cartoes de Debito,Redecard,GRUPO COM ORTOBOM N MIL   ,000317,DIARIO         ,V1.01 - 09/06 - EEVD
// 01,009864300,04092007,03092007,246051160,000001,000000000013860,000000000000277,000000000013583,D,422,000006,00000375205
// 05,009864300,246051160,03092007,000000000013860,000000000000277,000000000013583,5899160551808137   ,V,000005135959,04092007,01,192847,IC148399,2 ,00000
// 02,009864300,001,000001,000000000013860,000000000000277,000000000013583,000000000000000,000000000000000,000000000000000
// 03,009864300,009,000009,000000000362340,000000000007260,000000000355080,000000000000000,000000000000000,000000000000000
// 04,013466828,000090,000109,000000002591847,000000000051850,000000002539997,000000000000000,000000000000000,000000000000000,000294
// @MAILBOPV NAO CADASTRADO GE  EEVD
// 00,010864512,04092007,03092007,Movimentacao diaria - Cartoes de Debito,Redecard,00000000000000000000000000,000294,DIARIO         ,V1.01 - 09/06 - EEVD
// 04,010864512,000000,000000,000000000000000,000000000000000,000000000000000,000000000000000,000000000000000,000000000000000,000002

While !Eof()
	*/

	FT_FGOTOP()
	While (!FT_FEOF() )
		//Peder Munksgaard - 11/07/2018
		//Correção do problema de codepage que ocorria devido a
		//palavra comissão.
		//cBuffer := AllTrim(FT_FREADLN())
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		//
		/************************************
	* Trecho para a manipulacao do TXT. *
		************************************/
		//	RecLock("TXT",.F.)
		Arruma()
		//	MsUnLock()

		If cCampo01 == "1" .OR. cCampo01 == "01"   // No antigo
			//			Case cCampo01 == "01"   // No novo
			//
			cAdmin   := "19" //RedShop
			cBanco   := Padr(Alltrim(Strzero(Val(cCampo11),03)),03)
			cAgencia := Padr(Alltrim(Strzero(Val(cCampo12),05)),05)
			cConta   := Alltrim(Padr(Alltrim(Str(Val(cCampo13))),10))
			nLeErro:=0

			cPv     := "" //TP4->PA4_PV
			_cEmpZF := "" //TP4->PA4_CODEMP
			_cFilZF := "" //TP4->PA4_CODFIL
			//		TP4->(dbCloseArea())

		ElseIf cCampo01 == "5" .OR. cCampo01 == "05" // No antigo
			//			Case cCampo01 == "05"  // No novo

			cId      := "14" //Transações de Débito
			cPv      := cCampo02
			cResumo  := cCampo03
			dDataven := Ctod(Substr(cCampo04,1,2)+"/"+Substr(cCampo04,3,2)+"/"+Substr(cCampo04,7,2))
			dDataPg  := Ctod(Substr(cCampo11,1,2)+"/"+Substr(cCampo11,3,2)+"/"+Substr(cCampo11,7,2))
			cCartao  := cCampo08
			cCodAut  := alltrim(str(val(Substr(cCampo10,4,9))))   //6,7)
			cParcela := "01"
			cTotParc := "01"
			cTipo    := "CD"
			nValliq  := Val(Substr(cCampo07,1,13))+Val(Substr(cCampo07,14,2))/100
			nValbrut := Val(Substr(cCampo05,1,13))+Val(Substr(cCampo05,14,2))/100
			nValtx   := Val(Substr(cCampo06,1,13))+Val(Substr(cCampo06,14,2))/100
			nValtx   := 0 - nValtx
			cDescric := "REDSHOP"
			nLeErro:=0

			cNoPOS	 := cCampo14 //[BRUNO:29/11/2010 - Pegar numero de POS(maquineta)

			//Gravação da Tabela SZF com a confirmação das Vendas Aprovadas pela Administradora.
			//		GeraSZF("C")
			GeraSZF("B")
		ElseIf cCampo01 $ "2|02|3|03|4|04|6|06|7|07|11|011"
			//Codigo desprezado pelo microsiga
		Else
			nLeErro++
		EndIf

		if nLeErro > 10
			//		u_log_erro("Erro ao ler o aquivo >> " + Alltrim(cFile))
			nErros++
			//		exit
			//		Comentado por Marcos Furtado - 11/12/13. Não se pode garantir que não vira linhas válidas após 10 linhas desconsideradas.
		endif

		//	DbSkip()
		FT_FSKIP()

	EndDo

	//DbSelectArea("TXT")
	//DbCloseArea()

	FT_FUSE()

Return()

/****************************************************************************
* Programa....: RedeCard                                                    *
* Finalidade..: Leitura do arquivo txt dos cartões de Crédito RedeCard para *
*                a alimentação da tabela de Movimento de Cartões.           *
* Data........: 06/03/06                                                    *
*****************************************************************************/

Static Function RedeCard()
	Local n
	Local _aPos := {},_nPos
	Private _cBand := "REDECARD"

	//Reinicia Variáveis
	_cEmpZF := "  "
	_cFilZF := "  "
	cAdmin  := "12"
	vVettxt := {}
	cResumo  := ""
	cCartao  := ""
	cCodAut  := ""
	cParcela := "  "
	cTotParc := "  "
	cId      := ""
	cBanco   := ""
	cAgencia := ""
	cConta   := ""
	cTipo    := ""
	cPv      := ""
	cDescric := ""
	dDatapg  := ""
	dDataven := ""
	nValliq  := 0
	nValbrut := 0
	nValtx   := 0
	nTotParc := 0
	nVlparc  := 0
	nValParc := 0
	nTotComp := 0
	nTotDesc := 0
	nValDesc := 0
	nValDes  := 0
	nLeErro  := 0
	nTotBrut := 0

	cAdmOri	 := ""
	cNoPOS   := ""


	/********************************
* Criacao de Tabela temporaria. *
	********************************/

	// Trecho de codigo comentado por Luzio para passar a utilizar o comando FT_FUS no lugar do APPEND
	// Por isso este trecho foi duplicado

	/*
aAdd(vVettxt,{"cBuffer","C",500,0})

cArqvettxt := CriaTrab(vVettxt, .T.)
dbUseArea(.T.,,cArqvettxt,"REDE",.F.)
dbSelectArea("REDE")
Append From (cFile) SDF

dbGoTop()

//          1         2         3         4         5         6         7         8         9         0         1         2         3         4
// 12345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890
// 00203092007REDECARDEXTRATO DE MOVIMENTO DE VENDASGRUPO COM ORTOBOM N MI000228013466828DIARIO         V2.01 - 09/06 - EEVC

// 004009864300ORTOBON

// 01001367190108774915142200006000003752050209200700001000000000096250000000000000000000000000000000000000000002888000000000093362031020070

// 00701367190108774915102092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070136720370000000000000000000000000000000000000002092007000000000000000000000000000

// 00701367190108774915102092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070143427310000000000000000000000000000000000000002092007000000000000000000000000000

// 012013671901087749151020920070000000000000000009625000000000000000054882601****439800005000004079274             000000000002888019054153910                                                                2000000000093362000000000018670000000000018673IC160652   00000

// 01401367190108774915102092007000000000100000000001925000000000000058000000000001867003102007

// 01401367190108774915102092007000000000200000000001925000000000000057700000000001867305112007

// 01401367190108774915102092007000000000300000000001925000000000000057700000000001867303122007

// 01401367190108774915102092007000000000400000000001925000000000000057700000000001867303012008

// 01401367190108774915102092007000000000500000000001925000000000000057700000000001867306022008


// 026009864300000000001252528000000000000000000000000000000000000000000001252528000000000000000000000000000000000000000044665000000001207863000000000000000000000000000000000012

// 004009883355COLCHOES ORTOBOM

// 00601367369602723176242200006000003751913008200700001000000000120000000000000000000000000000000000000000000003600000000000116400011020070
// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070149725140000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000007100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070149730730000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070180801030000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070180809280000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070180809520000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070149733910000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070149727860000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070180798650000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070149737400000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070149738200000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070180786210000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070149729050000000000000000000000000000000000000030082007000000000000000000000000000

// 00701367369602723176202092007000000000009100D28AL.POS/TX.CONECT                            00000000000000000               000000000820070149736770000000000000000000000000000000000000030082007000000000000000000000000000

// 008013673696027231762300820070000000000000000012000000000000000000054485982****9740000000004428587             00000000000360037982 170512                                                                20000000001164002T368570   00000

// 01001367470608774916042200006000003751913008200700001000000000016500000000000000000000000000000000000000000000495000000000016005011020070

// 026013426630000000002890295000000000000000000000000000000136500000000002753795000000000000000000000000000000000000000108423000000002781872000000000000000000000000000000000054

// 0280007001153013466828000000010304280000000000000000000000000000000341636000000009962644000000000000000000000000000000000000000389004000000009915276000000000000000000000000000000000148


While !Eof()
	*/

	FT_FGOTOP()

	cJaLido:=""  && Henrique - SSI 31895
	While ( ! FT_FEOF() )
		//Peder Munksgaard - 11/07/2018
		//Correção do problema de codepage que ocorria devido a
		//palavra comissão.
		//cBuffer := AllTrim(FT_FREADLN())
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		//
		/************************************
	* Trecho para a manipulacao do TXT. *
		************************************/
		//RecLock("RedCard",.F.)
		//Arruma()
		//MsUnLock()

		If Substr(cBuffer,1,3) == "004"

			//[BRUNO:25/10/11] CORRECAO DO PV
			//cPv     := Alltrim(Str(Val(Substr(cBuffer,4,9)),9))
			nLeErro:=0

			_cEmpZF := ""
			_cFilZF := ""

		ElseIf Substr(cBuffer,1,3) == "006"

			cBanco  := Padr(Alltrim(Strzero(Val(Substr(cBuffer,22,03)),03)),03)
			cAgencia:= Padr(Alltrim(Strzero(Val(Substr(cBuffer,25,05)),05)),05)
			cConta  := Alltrim(Padr(Alltrim(Str(Val(Substr(cBuffer,30,11)))),10))
			cTotParc:= "  "
			cAdmin  := "12"
			cParcela:= "  "
			//		dDatapg := stod(Substr(cBuffer,129,08))
			dDatapg := stod(Substr(cBuffer,133,4)+Substr(cBuffer,131,2)+Substr(cBuffer,129,2))
			nValtx  := Val(Substr(cBuffer,099,15))/100
			nValtx  := 0 - nValtx
			nValliq := Val(Substr(cBuffer,114,15))/100
			nValbrut:= Val(Substr(cBuffer,054,15))/100
			nLeErro := 0

			//[BRUNO:26/11/2010]
			cAdmOri:= SubStr(cBuffer,137,1)
			cAdmOri	 := iif(cAdmOri=="3","11",cAdmin)     //Bandeira de Origem: Visa

		ElseIf Substr(cBuffer,1,3) == "007"

			cAdmin  := "12"
			cTotParc:= "  "
			cParcela:= "  "
			nValtx  := 0
			nValliq := 0
			nValbrut:= Val(Substr(cBuffer,030,15))/100
			//		dDataven:= Substr(cBuffer,22,08)  // Formato DDMMAAAA
			dDataven:= stod(Substr(cBuffer,26,4)+Substr(cBuffer,24,2)+Substr(cBuffer,22,2))
			//		dDataven:= Ctod(Substr(dDataven,1,2)+"/"+Substr(dDataven,3,2)+"/"+Substr(dDataven,7,2))
			//		dDataven:= iif(empty(dDataven),ddatabase,stod(ddataven))
			dDataPg := dDataBase
			cResumo := Substr(cBuffer,013,09)
			cTipo   := "CC"
			cAdmin  := "12"
			cCartao := AllTrim(Substr(cBuffer,076,16))
			cCodAut := Substr(cBuffer,208,12)

			If Substr(cBuffer,46,2) == "28"

				cId := "12" //POS
				cDescric:= "ALUGUEL DE POS" //Motivo do Ajuste

				_nPos := aScan(_aPos,{|x| Alltrim(x[1])==Alltrim(cPV)})
				If _nPos==0
					//					aAdd(_aPos,{Alltrim(cPv),nValBrut})
					aAdd(_aPos,{Alltrim(cPV),nValBrut,cResumo,dDataVen,dDataPG,cBanco,cAgencia,cConta,"12"})
				Else
					_aPos[_nPos,2] += nValBrut
				Endif

			Else

				If Substr(cBuffer,46,2) == "02"

					cId := "02" //Ajuste
					cDescric:= "CONSULTA NO SERASA" //Motivo do Ajuste

				Else

					cId := "07" //Ajuste
					cDescric:= Substr(cBuffer,48,28) //Motivo do Ajuste

				EndIf

				nLeErro:=0

				//Gravação da Tabela SZF com a confirmação das Vendas Aprovadas pela Administradora.
				GeraSZF("A")

			EndIf

			/*
		ElseIf Substr(cBuffer,1,3) == "008"

		dDataven:= stod(Substr(cBuffer,26,4)+Substr(cBuffer,24,2)+Substr(cBuffer,22,2)))
		cResumo := Substr(cBuffer,13,09)
		cTipo   := "CC"
		cAdmin  := "12"
		cCartao := Substr(cBuffer,68,16)
		cCodAut := alltrim(str(val(Substr(cBuffer,87,12))))
		cId     := "14"
		cDescric:= "REDECARD ROTATIVO"
		nLeErro := 0
		//Gravação da Tabela SZF com a confirmação das Vendas Aprovadas pela Administradora.
		GeraSZF("A")
			*/

		ElseIf Substr(cBuffer,1,3) == "010"

			cBanco   := Padr(Alltrim(Strzero(Val(Substr(cBuffer,22,03)),03)),03)
			cAgencia := Padr(Alltrim(Strzero(Val(Substr(cBuffer,25,05)),05)),05)
			cConta   := Alltrim(Padr(Alltrim(Str(Val(Substr(cBuffer,30,11)))),10))
			nLeErro  := 0

			//[BRUNO:26/11/2010]
			cAdmOri:= SubStr(cBuffer,137,1)
			cAdmOri	 := iif(cAdmOri=="3","11",cAdmin)     //Bandeira de Origem: Visa


		ElseIf Substr(cBuffer,1,3) == "012" .or. Substr(cBuffer,1,3) == "008"

			nVlparc  := 0
			nValParc := 0
			nTotComp := 0
			nTotDesc := 0
			nValDesc := 0
			nValDes  := 0
			nTotBrut := 0
			nTotTx   := 0

			//[BRUNO:25/10/11] CORRECAO DO PV
			cPv     := Alltrim(StrZero(Val(Substr(cBuffer,4,9)),9))
			dDataven:= stod(Substr(cBuffer,26,4)+Substr(cBuffer,24,2)+Substr(cBuffer,22,2))
			cResumo := Substr(cBuffer,13,09)
			cTipo   := "CC"
			cAdmin  := "12"
			cCartao := AllTrim(Substr(cBuffer,68,16))
			If Substr(cBuffer,1,3) == "012"
				cCodAut  := alltrim(str(val(Substr(cBuffer,89,12))))
				cDescric := "REDECARD PARCELADO"
				cTotParc := Substr(cBuffer,87,02)
				nValtx   := Val(Substr(cBuffer,114,15))/100
			Else
				cCodAut  := alltrim(str(val(Substr(cBuffer,87,12))))
				cDescric := "REDECARD ROTATIVO"
				cTotParc := '01'
				nValtx   := Val(Substr(cBuffer,112,15))/100
			EndIf
			If Empty(cTotParc)
				cTotParc := '01'
			EndIf

			cId      := "14"
			nValbrut := Val(Substr(cBuffer,038,15))/100
			nTotbrut := Val(Substr(cBuffer,038,15))/100
			nTotTx   := nValtx
			nTotParc := Val(cTotParc)
			dData    := dDataven  // Formato stod(AAAAMMDD) esta em formato data invertido

			//[BRUNO:29/11/2010 - Pegar numero de POS(maquineta)
			if  Substr(cBuffer,1,3) == "008"
				cNoPos:= Substr(cBuffer,219,8)
			elseif Substr(cBuffer,1,3) == "012"
				cNoPos:= Substr(cBuffer,251,8)
			endif

			if nTotParc > 0
				nVlparc := NoRound(nValbrut / nTotParc,2)
			endif

			nValDesc := nValtx / nTotParc
			/*
		If nTotParc > 15
			//nBtLidos := fRead(nHdl,@cBuffer,nTamLin)
			//			dbskip()
			//FT_FSKIP()
			//Loop
		EndIf
			*/
			For n := 1 to nTotParc

				dData   := dData + 30
				dDatapg := DataValida(dData)

				If n = nTotParc
					nValParc := nTotbrut - nTotComp
					nValDes  := nTottx   - nTotDesc     //nValTx   - nTotDesc
				Else
					nValParc := nVlparc
					nValDes  := nValDesc

					nTotComp += nVlParc
					nTotDesc += nValDesc
				Endif

				//			nValbrut := IIF(n = 1, nValParc, nVlparc)
				//			nValtx   := IIF(n = 1, nValDes, nValDesc)
				nValbrut := nValParc
				nValtx   := nValDes

				nValliq  := nValbrut - nValtx
				nValtx   := 0 - nValtx
				//Tratamento de Parcela, informação origem do vetor vParc
				cParcela := vParc[n]
				nLeErro:=0
				//Gravação da Tabela SZF com a confirmação das Vendas Aprovadas pela Administradora.
				GeraSZF("A")

			Next

		ElseIf Substr(cBuffer,1,3) == "014"

			// Este trecho de codigo foi desativado, porque os regsitros enviados pela administradora no arquivo pode conter
			// mais de um cartao de credito para uma mesma autorizacao, o que causaria erro na quitacao das parcelas
			// uma vez que a mesma
			// Segue trecho do arquivo:

			/*/
		01001341984606254968042200006000003751671609200700002000000000193600000000000000000000000000000000000000000007744000000000185856171020070

		012013419846062549680160920070000000000000000012710000000000000000052746802****719900010000998069492             00000000000508481809 210254                                                                2000000000122016000000000012198000000000012202IM002265   00000

		012013419846062549680160920070000000000000000006650000000000000000054857394****697800010000998285222             000000000002660035795185231                                                                2000000000063840000000000006384000000000006384IM002265   00000

		01401341984606254968016092007000000000100000000001936000000000000077800000000001858217102007

		01401341984606254968016092007000000000200000000001936000000000000077400000000001858619112007

		01401341984606254968016092007000000000300000000001936000000000000077400000000001858617122007

		01401341984606254968016092007000000000400000000001936000000000000077400000000001858617012008

		01401341984606254968016092007000000000500000000001936000000000000077400000000001858618022008

		01401341984606254968016092007000000000600000000001936000000000000077400000000001858617032008

		01401341984606254968016092007000000000700000000001936000000000000077400000000001858617042008

		01401341984606254968016092007000000000800000000001936000000000000077400000000001858619052008

		01401341984606254968016092007000000000900000000001936000000000000077400000000001858617062008

		01401341984606254968016092007000000001000000000001936000000000000077400000000001858617072008

			/*/

			/*
		nVlparc  := 0
		nValParc := 0
		nTotComp := 0
		nTotDesc := 0
		nValDesc := 0
		nValDes  := 0
		nTotBrut := 0
		nTotTx := 0

		nValbrut := Val(Substr(cBuffer,040,15))/100
		nValtx   := Val(Substr(cBuffer,055,15))/100
		nVlparc := Val(Substr(cBuffer,040,15))/100

		nValDesc:= nValtx / nTotParc

		If nTotParc > 15
		//nBtLidos := fRead(nHdl,@cBuffer,nTamLin)
		//			dbskip()
		FT_FSKIP()
		Loop
		EndIf

		dDatapg := stod(Substr(cBuffer,89,4)+Substr(cBuffer,87,2)+Substr(cBuffer,85,2))

		nValliq  := nValbrut - nValtx
		nValtx   := 0 - nValtx

		//Tratamento de Parcela, informação origem do vetor vParc
		cParcela := vParc[Val(Substr(cBuffer,038,2))]

		//Gravação da Tabela SZF com a confirmação das Vendas Aprovadas pela Administradora.
		GeraSZF("A")
			*/

			nLeErro := 0

		ElseIf Substr(cBuffer,1,3) == "011" //Surgiu em um dos arquivos como PGTO DE RV . [BRUNO:07/01/2010]

			nLeErro := 0

			//EEFI V4.00 - Header do arquivo (030) e Header do solicitante (032)
			//EEVC V3.00 - Header (002), Totalizador matriz (026), Trailer (028)
		ElseIf Substr(cBuffer,1,3) == "030" .OR. Substr(cBuffer,1,3) == "032" .OR.;
				Substr(cBuffer,1,3) == "002" .OR. Substr(cBuffer,1,3) == "026" .OR.;
				Substr(cBuffer,1,3) == "028"
			nLeErro := 0

		ElseIf Substr(cBuffer,1,3) == "034" //EEFI V4.00 - Ordem de Credito (Baixa Normal)
			//Layout EEFI registro 034:
			//pos 004-012: PV (9)
			//pos 013-021: Numero do documento/OC (9)
			//pos 024-031: Data do lancamento (DDMMAAAA)
			//pos 032-046: Valor do lancamento (15)
			//pos 047:     Indicador C=Credit / D=Debit
			//pos 048-050: Banco (3)
			//pos 051-055: Agencia (5)
			//pos 056-066: Conta corrente (11)
			//pos 076-084: Numero do RV (9)
			//pos 085-092: Data do RV (DDMMAAAA)
			nLeErro := 0
			cPA7_RESUMO := SubStr(cBuffer,076,09)
			cPA7_PV     := SubStr(cBuffer,004,09)
			cDtLanc     := SubStr(cBuffer,024,08)
			nVlLanc     := Val(SubStr(cBuffer,032,15))/100
			//Localiza PA7 por resumo (RV) para confirmar pagamento
			If !Empty(cPA7_RESUMO) .And. nVlLanc > 0
				nRegPA7 := PA7->(RecNo())
				PA7->(DbSetOrder(1))
				If PA7->(DbSeek(xFilial("PA7") + "12" + cPA7_RESUMO))
					Conout("ORTA023D - EEFI 034 pagamento encontrado RV="+AllTrim(cPA7_RESUMO)+" PV="+AllTrim(cPA7_PV)+" Valor="+AllTrim(Str(nVlLanc)))
				EndIf
				PA7->(DbGoTo(nRegPA7))
			EndIf
		ElseIf Substr(cBuffer,1,3) == "036" && Dupim - Baixa Antecipada
			nLeErro := 0
		ElseIf Substr(cBuffer,1,3) == "037" //EEFI V4.00 - Totalizador de Creditos
			nLeErro := 0
		ElseIf Substr(cBuffer,1,3) == "053" //EEFI V4.00 - Ajustes Net E-Commerce
			nLeErro := 0
		ElseIf Substr(cBuffer,1,3) == "040" && Dupim - SERASA
			nLeErro := 0
		ElseIf Substr(cBuffer,1,3) == "035" && Dupim - SSI 51352

			nLeErro := 0
			cPA7_AUTORI:=Alltrim(Str(val(SubStr(cBuffer,242,09))))
			cPA7_PV    :=SubStr(cBuffer,004,09)
			cPA7_RESUMO:=SubStr(cBuffer,013,09)
			cDtCanc    :=SubStr(cBuffer,022,08)
			cMotAju    :=SubStr(cBuffer,046,02)
			dPA7_DTCANC:=CToD(Left(cDtCanc,2) + "/" + Substr(cDtCanc,3,2) + "/" + Right(cDtCanc,4))
			nPA7_VLCANC:=Val(SubStr(cBuffer,030,15))/100
			if cMotAju$"08#09#10#15#16#18#21#22#23#32#87"
				nRegPA7    :=PA7->(RecNo())
				PA7->(DbSetOrder(02))
				//nOrdPA7    :=PA7->(DbSetOrder(02))
				If PA7->(DbSeek(xFilial("PA7") + cPA7_AUTORI))
					If AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. (AllTrim(PA7->PA7_PV) # AllTrim(cPA7_PV) .OR. AllTrim(PA7->PA7_RESUMO) # AllTrim(cPA7_RESUMO))
						While AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. (AllTrim(PA7->PA7_PV) # AllTrim(cPA7_PV) .OR. AllTrim(PA7->PA7_RESUMO) # AllTrim(cPA7_RESUMO)) .AND. ! PA7->(Eof())
							PA7->(DbSkip())
						End
					EndIf
					If AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. AllTrim(PA7->PA7_PV) == AllTrim(cPA7_PV) .AND. AllTrim(PA7->PA7_RESUMO) == AllTrim(cPA7_RESUMO)
						If PA7->(RecLock("PA7",.F.))
							if !empty(dPA7_DTCANC)
								if PA7->PA7_DTCANC>=dPA7_DTCANC
									PA7->PA7_VLCANC+=nPA7_VLCANC
								else
									PA7->PA7_VLCANC:=nPA7_VLCANC
								Endif
								PA7->PA7_DTCANC:=dPA7_DTCANC
							endif
							PA7->(MsUnlock())
						EndIf
					EndIf
				EndIf
				PA7->(DbSetOrder(02))
				PA7->(DbGoTo(nRegPA7))
			Endif

			//ElseIf Substr(cBuffer,1,3) == "035" && fabio - cida reclamou
			// parece que existem 2 layouts do arquivo, pois existem registros preenchidos
			nLeErro := 0
			cPA7_AUTORI:=Alltrim(Str(val(SubStr(cBuffer,242,09))))
			cPA7_PV    :=SubStr(cBuffer,138,09)
			cPA7_RESUMO:=SubStr(cBuffer,013,09)
			cDtCanc    :=SubStr(cBuffer,022,08)
			cMotAju    :=SubStr(cBuffer,046,02)
			dPA7_DTCANC:=CToD(Left(cDtCanc,2) + "/" + Substr(cDtCanc,3,2) + "/" + Right(cDtCanc,4))
			nPA7_VLCANC:=Val(SubStr(cBuffer,030,15))/100
			if cMotAju$"08#09#10#15#16#18#21#22#23#32#87"
				nRegPA7    :=PA7->(RecNo())
				//nOrdPA7    :=PA7->(DbSetOrder(02))
				PA7->(DbSetOrder(02))
				If PA7->(DbSeek(xFilial("PA7") + cPA7_AUTORI))
					If AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. (AllTrim(PA7->PA7_PV) # AllTrim(cPA7_PV) .OR. AllTrim(PA7->PA7_RESUMO) # AllTrim(cPA7_RESUMO))
						While AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. (AllTrim(PA7->PA7_PV) # AllTrim(cPA7_PV) .OR. AllTrim(PA7->PA7_RESUMO) # AllTrim(cPA7_RESUMO)) .AND. ! PA7->(Eof())
							PA7->(DbSkip())
						End
					EndIf
					If AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. AllTrim(PA7->PA7_PV) == AllTrim(cPA7_PV) .AND. AllTrim(PA7->PA7_RESUMO) == AllTrim(cPA7_RESUMO)
						If PA7->(RecLock("PA7",.F.))
							if !empty(dPA7_DTCANC)
								if PA7->PA7_DTCANC>=dPA7_DTCANC
									PA7->PA7_VLCANC+=nPA7_VLCANC
								else
									PA7->PA7_VLCANC:=nPA7_VLCANC
								Endif
								PA7->PA7_DTCANC:=dPA7_DTCANC
							endif
							PA7->(MsUnlock())
						EndIf
					EndIf
				EndIf
				PA7->(DbSetOrder(02))
				PA7->(DbGoTo(nRegPA7))
			Endif
		ElseIf Substr(cBuffer,1,3) == "045" && Dupim - SSI 51352

			nLeErro := 0
			cPA7_AUTORI:=Alltrim(Str(val(SubStr(cBuffer,096,09))))
			cPA7_PV    :=SubStr(cBuffer,151,09)
			cPA7_RESUMO:=SubStr(cBuffer,134,09)
			cDtCanc    :=SubStr(cBuffer,024,08)
			cDtVend    :=SubStr(cBuffer,105,08)
			cMotAju    :=SubStr(cBuffer,047,02)
			cPA7_CARTAO:=Substr(cBuffer,077,02)
			dPA7_DTVEND:=CToD(Left(cDtVend,2) + "/" + Substr(cDtVend,3,2) + "/" + Right(cDtVend,4))
			dPA7_DTCANC:=CToD(Left(cDtCanc,2) + "/" + Substr(cDtCanc,3,2) + "/" + Right(cDtCanc,4))
			nPA7_VLCANC:=Val(SubStr(cBuffer,119,15))/100
			if cMotAju$"08#09#10#15#16#18#21#22#23#32#87"
				nRegPA7    :=PA7->(RecNo())
				//nOrdPA7    :=PA7->(DbSetOrder(02))
				PA7->(DbSetOrder(02))
				If PA7->(DbSeek(xFilial("PA7") + cPA7_AUTORI))
					If AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. (AllTrim(PA7->PA7_PV) # AllTrim(cPA7_PV) .OR. AllTrim(PA7->PA7_DTVEND) # AllTrim(dPA7_DTVEND))
						While AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. (AllTrim(PA7->PA7_PV) # AllTrim(cPA7_PV) .OR. AllTrim(PA7->PA7_DTVEND) # AllTrim(dPA7_DTVEND)) .AND. ! PA7->(Eof())
							PA7->(DbSkip())
						End
					EndIf
					If AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. AllTrim(PA7->PA7_PV) == AllTrim(cPA7_PV) .AND. AllTrim(PA7->PA7_DTVEND) == AllTrim(dPA7_DTVEND)
						If PA7->(RecLock("PA7",.F.))
							if !empty(dPA7_DTCANC)
								if PA7->PA7_DTCANC>=dPA7_DTCANC
									PA7->PA7_VLCANC+=nPA7_VLCANC
								else
									PA7->PA7_VLCANC:=nPA7_VLCANC
								Endif
								PA7->PA7_DTCANC:=dPA7_DTCANC
							endif
							PA7->(MsUnlock())
						EndIf
					EndIf
				EndIf
				PA7->(DbSetOrder(02))
				PA7->(DbGoTo(nRegPA7))
			Endif
		ElseIf Substr(cBuffer,1,3) == "049" && Henrique - SSI 31895 (Cancelamento)
			cPA7_AUTORI:=Alltrim(Str(val(SubStr(cBuffer,155,09)))) //SubStr(cBuffer,155,09)
			cPA7_PV    :=SubStr(cBuffer,004,09)
			cPA7_RESUMO:=SubStr(cBuffer,013,09)
			cDtCanc    :=SubStr(cBuffer,090,08)
			dPA7_DTCANC:=CToD(Left(cDtCanc,2) + "/" + Substr(cDtCanc,3,2) + "/" + Right(cDtCanc,4))
			nPA7_VLCANC:=Val(SubStr(cBuffer,113,15))/100
			nRegPA7    :=PA7->(RecNo())
			//nOrdPA7    :=PA7->(DbSetOrder(02))
			PA7->(DbSetOrder(02))
			If PA7->(DbSeek(xFilial("PA7") + cPA7_AUTORI))
				If AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. (AllTrim(PA7->PA7_PV) # AllTrim(cPA7_PV) .OR. AllTrim(PA7->PA7_RESUMO) # AllTrim(cPA7_RESUMO))
					While AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. (AllTrim(PA7->PA7_PV) # AllTrim(cPA7_PV) .OR. AllTrim(PA7->PA7_RESUMO) # AllTrim(cPA7_RESUMO)) .AND. ! PA7->(Eof())
						PA7->(DbSkip())
					End
				EndIf

				If AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. AllTrim(PA7->PA7_PV) == AllTrim(cPA7_PV) .AND. AllTrim(PA7->PA7_RESUMO) == AllTrim(cPA7_RESUMO)
					If PA7->(RecLock("PA7",.F.))
						if !empty(dPA7_DTCANC)
							if !empty(dPA7_DTCANC)
								if PA7->PA7_DTCANC>=dPA7_DTCANC
									PA7->PA7_VLCANC+=nPA7_VLCANC
								else
									PA7->PA7_VLCANC:=nPA7_VLCANC
								Endif
								PA7->PA7_DTCANC:=dPA7_DTCANC
							endif
						endif
						PA7->(MsUnlock())
					EndIf
				EndIf
			EndIf
			PA7->(DbSetOrder(02))
			PA7->(DbGoTo(nRegPA7))
		ElseIf Substr(cBuffer,1,3) == "050" .OR. Substr(cBuffer,1,3) == "052" //EEFI V4.00 - Trailer
			nLeErro := 0
		Else

			nLeErro++

		EndIf

		if nLeErro > 10
			//		u_log_erro("Erro ao ler o aquivo >> " + Alltrim(cFile))
			nErros++
			//		exit
			//		Comentado por Marcos Furtado - 11/12/13. Não se pode garantir que não vira linhas válidas após 10 linhas desconsideradas.
		endif

		FT_FSKIP()
	EndDo

	//	dbskip()
	//EndDo

	// Gera Titulo de Aluguel de POS, caso exista
	If len(_aPos) > 0
		gerapos(_apos)
	Endif

	//DbSelectArea("REDE")
	//DbCloseArea()
	FT_FUSE()

Return()

/**************************************************************************
* Programa....: Visa                                                      *
* Finalidade..: Leitura do arquivo txt dos cartões de Crédito e Débito    *
*               Visa para a alimentação da tabela de Movimento de Cartões *
* Data........: 24/02/06                                                  *
**************************************************************************/
Static Function Visa()
	Local _aPos := {},_nPos
	Local _lret := .t.
	Local n := 1
	Private _aTitBx := {}
	Private _cBand := "VISA"

	//Reinicia Variáveis
	_cEmpZF := "  "
	_cFilZF := "  "
	cAdmin   := "11"
	vVettxt  := {}
	cResumo  := ""
	cCartao  := ""
	cCodAut  := ""
	cParcela := "  "
	cTotParc := "  "
	cDescric := ""
	cBanco   := ""
	cAgencia := ""
	cConta   := ""
	cTipo    := ""
	cId      := ""
	cPv      := ""
	dDataven := ""
	dDatapg  := ""
	dDataPag := ""
	nValliq1 := 0
	nValbrut1:= 0
	nValtx1  := 0
	nValliq  := 0
	nValbrut := 0
	nValtx   := 0
	nPerc    := 0

	nTotParc := 0
	nVlparc  := 0
	nValParc := 0
	nTotComp := 0
	nValDesc := 0
	nValDes  := 0
	nTotDesc := 0
	nTotLiq  := 0
	nParcela := 0

	_cTpAj   := ""
	cBaixar  := .f.
	nLeErro  := 0
	_aPOS    := {}

	cAdmOri	 := ""
	cNoPOS   := ""


	/********************************
* Criacao de Tabela temporaria. *
	*********************************/

	/*
aAdd(vVettxt,{"cBuffer","C",500,0})

cArqvettxt := CriaTrab(vVettxt, .T.)
dbUseArea(.T.,,cArqvettxt,"VISA",.F.)
dbSelectArea("VISA")
Append From (cFile) SDF

dbGoTop()

//          1         2         3         4         5         6         7         8         9         0
// 12345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890
// 01006981940200709022007090220070902LIQ0003308VISANETDPDEP  COM  CV /
// 110017961920070831     LIQUIDACAO   14070831071001000000+0000000008200-0000000000205+0000000000000+000000000799504220060000000000375167000001 000000 D070901
// 210017961920070831453211400923307100020070831+00000000082000000                              098610                                        039084000000000000016                          000000000    25846556
// 14563048470407030107/10LIQUIDACAO   14070901071002000000+0000000008020-0000000000281+0000000000000+000000000773904220060000000000375183000001 000000 D070901
// 245630484704070301498446956591172300020070301+00000000080200710                              010821                                        000000000000000000016                          000000000    00000000

While !Eof()
	*/

	FT_FGOTOP()

	While ( ! FT_FEOF() )
		//Peder Munksgaard - 11/07/2018
		//Correção do problema de codepage que ocorria devido a
		//palavra comissão.
		//cBuffer := AllTrim(FT_FREADLN())
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		//

		_lret := .t.
		/* Tipos de Movimentacao VISA
	07 - Ajuste a credito ou debito
	12 - aluguel de POS
	13 - capturado
	14 - Liquidacao
	19 - Cach-Back
		*/

		// Bloqueia arquivos com data anterior a 01/01/2005
		If Substr(cBuffer,1,1) == '0' .AND. Val(Substr(cBuffer,12,8)) < 20050101   //Substr(cBuffer,12,8) < '20050101'

			nLeErro := 15

			// le linha de cabecalho e preenche variavel cPv com o estabelecimento
		ElseIf Substr(cBuffer,1,1) == '0'

			//[BRUNO:25/10/2011]
			//cPv      := Substr(cBuffer,02,10)
			nLeErro:=0

			_cEmpZF := "" //TP4->PA4_CODEMP
			_cFilZF := "" //TP4->PA4_CODFIL


			// Processa Aluguel de POS
		ElseIf Substr(cBuffer,1,1) == '1' .And. Substr(cBuffer,37,2) == '12' .And. Substr(cBuffer,150,1) == 'D' //Aluguel de POS.

			cBaixar := .f.
			cId      := '12'
			cResumo  := Substr(cBuffer,12,07)
			dDataven := Ctod(Substr(Substr(cBuffer,39,06),5,2)+'/'+Substr(Substr(cBuffer,39,06),3,2)+'/'+Substr(Substr(cBuffer,39,06),1,2))
			dDataPag := Ctod(Substr(Substr(cBuffer,45,06),5,2)+'/'+Substr(Substr(cBuffer,45,06),3,2)+'/'+Substr(Substr(cBuffer,45,06),1,2))
			dDataPg  := Ctod(Substr(Substr(cBuffer,45,06),5,2)+'/'+Substr(Substr(cBuffer,45,06),3,2)+'/'+Substr(Substr(cBuffer,45,06),1,2))
			//				dDataPg  := stod(Substr(cBuffer,45,06))

			//		nValbrut := Val(Substr(cBuffer,058,11))+(Val(Substr(cBuffer,069,2))/100)
			//		nValliq  := Val(Substr(cBuffer,100,11))+(Val(Substr(cBuffer,111,2))/100)
			//		nValtx   := Val(Substr(cBuffer,072,11))+(Val(Substr(cBuffer,83,2))/100)

			nValbrut := Val(Substr(cBuffer,058,13))/100
			nValliq  := Val(Substr(cBuffer,100,13))/100
			nValtx1  := 0 - (Val(Substr(cBuffer,072,13))/100)
			nValtx   := nValtx1   //0

			cDescric := 'ALUGUEL DE POS'
			cBanco   := Alltrim(Padr(Alltrim(Strzero(Val(Substr(cBuffer,113,04)),03)),03))
			cAgencia := StrZero(Val(Alltrim(Padr(Alltrim(Strzero(Val(Substr(cBuffer,117,05)),05)),05))),4)
			cConta   := Alltrim(Padr(Alltrim(Str(Val(Substr(cBuffer,122,14)))),10))
			cCartao  := ''
			cCodAut  := ''
			cParcela := '  '
			cTotParc := '  '
			cTipo    := ''
			nLeErro:=0

			_nPos := aScan(_aPos,{|x| Alltrim(x[1])==Alltrim(cPV)})
			If _nPos==0
				aAdd(_aPos,{Alltrim(cPV),nValBrut,cResumo,dDataVen,dDataPG,cBanco,cAgencia,cConta,"12"})
			Else
				_aPos[_nPos,2] += nValBrut
			Endif

			//[BRUNO:26/11/2010]
			cAdmOri  := Alltrim(Substr(cBuffer,197,3))
			cAdmOri	 := iif(cAdmOri=="002","12",cAdmin)     //Bandeira de Origem: RedeCard


			// Processa Ajuste de Crédito ou Débito
		ElseIf Substr(cBuffer,1,1) == '1' .And. Substr(cBuffer,37,2) == '07' .And. Substr(cBuffer,150,1) == 'D'

			cBaixar := .f.
			// verificar posicionamento das variaveis
			cId      := '07'
			cTpID    := '1'
			cResumo  := Substr(cBuffer,12,07)
			dDataven := Ctod(Substr(Substr(cBuffer,39,06),5,2)+'/'+Substr(Substr(cBuffer,39,06),3,2)+'/'+Substr(Substr(cBuffer,39,06),1,2))
			dDataPag := Ctod(Substr(Substr(cBuffer,45,06),5,2)+'/'+Substr(Substr(cBuffer,45,06),3,2)+'/'+Substr(Substr(cBuffer,45,06),1,2))
			dDataPg  := Ctod(Substr(Substr(cBuffer,45,06),5,2)+'/'+Substr(Substr(cBuffer,45,06),3,2)+'/'+Substr(Substr(cBuffer,45,06),1,2))

			nValbrut := Val(Substr(cBuffer,058,13))/100
			nValliq  := Val(Substr(cBuffer,100,13))/100
			nValtx1  := 0 - (Val(Substr(cBuffer,072,13))/100)
			nValtx   := nValtx1   //0

			cBanco   := Alltrim(Padr(Alltrim(Strzero(Val(Substr(cBuffer,113,04)),03)),03))
			cAgencia := StrZero(Val(Alltrim(Padr(Alltrim(Strzero(Val(Substr(cBuffer,117,05)),05)),05))),4)
			cConta   := Alltrim(Padr(Alltrim(Str(Val(Substr(cBuffer,122,14)))),10))
			_cTpAj   := iif(Substr(cBuffer,57,1)=="+","C","D")
			cNumCart := " "
			cCodAut  := " "
			cparcela := "  "
			cDescric := Iif(_cTpAJ=="C","AJUSTE CREDITO","AJUSTE DEBITO")

			//[BRUNO:26/11/2010]
			cAdmOri  := Alltrim(Substr(cBuffer,197,3))

			If Substr(cBuffer,142,1) == 'E'
				cTipo := 'CD' //Débito
				cAdmin   := "18"
				cAdmOri	 := iif(cAdmOri=="002","19",cAdmin)     //Bandeira de Origem: RedeCard
			Else
				cTipo := 'CC' //Crédito
				cAdmin   := "11"
				cAdmOri	 := iif(cAdmOri=="002","12",cAdmin)     //Bandeira de Origem: RedeCard
			EndIf


			//		geraszf("C")
			geraszf("B")

			// Processa Liquidação.
		ElseiF Substr(cBuffer,1,1) == '1' .And. Substr(cBuffer,37,2) == '14' .And. Substr(cBuffer,150,1) == 'D'

			cBaixar := .f.
			// verificar posicionamento dos caracteres do resumo
			cId      := '14'
			cResumo  := Substr(cBuffer,12,07)
			dDataven := Ctod(Substr(Substr(cBuffer,39,06),5,2)+'/'+Substr(Substr(cBuffer,39,06),3,2)+'/'+Substr(Substr(cBuffer,39,06),1,2))
			dDataPag := Ctod(Substr(Substr(cBuffer,45,06),5,2)+'/'+Substr(Substr(cBuffer,45,06),3,2)+'/'+Substr(Substr(cBuffer,45,06),1,2))
			dDataPg  := Ctod(Substr(Substr(cBuffer,45,06),5,2)+'/'+Substr(Substr(cBuffer,45,06),3,2)+'/'+Substr(Substr(cBuffer,45,06),1,2))

			nValbrut := Val(Substr(cBuffer,058,13))/100
			nTotLiq  := Val(Substr(cBuffer,100,13))/100

			// Calcula o percentual de incidencia da comissao da Administradora do cartao para aplicar em cada parcela
			nValtx1  := Val(Substr(cBuffer,072,13))/100
			nPerc    := Round((nValtx1 * 100) / nValBrut , 2)    //Round((nValBrut * 100) / nValBrut1 , 2)
			nValtx   := 0 - nValtx1   //0

			cBanco   := Alltrim(Padr(Alltrim(Strzero(Val(Substr(cBuffer,113,04)),03)),03))
			cAgencia := StrZero(Val(Alltrim(Padr(Alltrim(Strzero(Val(Substr(cBuffer,117,05)),05)),05))),4)
			cConta   := Alltrim(Padr(Alltrim(Str(Val(Substr(cBuffer,122,14)))),10))
			_cTpAj   := iif(Substr(cBuffer,57,1)=="+","C","D")
			cNumCart := " "
			cCodAut  := " "
			cparcela := "  "
			cDescric := Iif(_cTpAJ=="C","AJUSTE CREDITO","AJUSTE DEBITO")

			//[BRUNO:26/11/2010]
			cAdmOri  := Alltrim(Substr(cBuffer,197,3))

			If Substr(cBuffer,142,1) == 'E'
				cTipo := 'CD' //Débito
				cAdmin   := "18"
				cAdmOri	 := iif(cAdmOri=="002","19",cAdmin)     //Bandeira de Origem: RedeCard
			Else
				cTipo := 'CC' //Crédito
				cAdmin   := "11"
				cAdmOri	 := iif(cAdmOri=="002","12",cAdmin)     //Bandeira de Origem: RedeCard
			EndIf

			nLeErro:=0

			// ELO - 08.12.06
			// verifica se existe SZF,SE1 e faz a baixa do titulo
			//
			If cTipo == 'CC'
				//			_lret := bx_resumo(cAdmin, cCodAut, cResumo, cParcela)
				//_lret := bx_resumo(cAdmin, cId, cCodAut, cResumo, cParcela)
				cBaixar := .t.
			Endif

			// Grava Titulo de CC e CD no SZF



		ElseIf Substr(cBuffer,1,1) == '2' //.AND. !empty(dDataven)

			nVlparc  := 0
			nValParc := 0
			nTotComp := 0
			nTotDesc := 0
			nValDesc := 0
			nValDes  := 0
			nTotBrut := 0
			nTotTx := 0

			cId      := '14'
			//[BRUNO:25/10/2011]
			cPv      := Substr(cBuffer,02,10)
			cCartao  := AllTrim(Substr(cBuffer,19,19))
			cCodAut  := Substr(cBuffer,140,6)+Substr(cBuffer,94,6) //NSU + Autorização
			cDescric := "TITULO VISA"

			dDataVen := stod(Substr(cBuffer,38,08))
			dData    := stod(Substr(cBuffer,38,08))

			nValbrut := Val(Substr(cBuffer,047,13))/100      //Val(Substr(cBuffer,048,11))+(Val(Substr(cBuffer,059,2))/100)
			nVlParc  := Val(Substr(cBuffer,047,13))/100      //Val(Substr(cBuffer,048,11))+(Val(Substr(cBuffer,059,2))/100)

			nValtx    := Round((nValbrut * nPerc)/100,2)
			nValliq   := nValbrut - nValtx
			nValtx    := 0 - nValtx
			//		nValDesc  := nValTx

			// Numero da Parcela que esta sendo liquidado. Se for a primeira parcela, ira gerar no SZF as demais parcelas,
			// caso contrario ira tratar a liquidacao da referida parcela.
			nParcela := Val(Substr(cBuffer,60,2))

			nTotParc := Val(Substr(cBuffer,62,2))
			cTotParc := Substr(cBuffer,62,2)

			nTotBrut := nValBrut * nTotParc
			nTottx   := nValtx * nTotParc

			If Substr(cBuffer,62,2) == '00'
				cTotParc := '01'
			EndIf

			/* venda em ate 21x
		If nTotParc > 15
			//nBtLidos := fRead(nHdl,@cBuffer,nTamLin)
			//			lerLinha(nHdl)   // Incluido por Luzio, nao existe no original, pode ser deletado
			//			DbSkip()
			FT_FSKIP()
			Loop
		EndIf
			*/

			//Tratamento de Parcela, informação origem do vetor vParc
			If Substr(cBuffer,60,2) == '00' .or. Empty(Substr(cBuffer,60,2))
				//			cParcela := ' '
				cParcela := vParc[1]
			Else
				cParcela := vParc[Val(Substr(cBuffer,60,2))]
			EndIf

			//[BRUNO:26/11/10]
			cNoPOS:= Substr(cBuffer,200,8) //No. do POS(Maquineta)

			****************************  AT E N C A O  *****************************************************
			// Trecho incluido por Luzio para calcular o valor de cada parcela so quando for a primeira parcela
			// Baixa da primeira parcela de uma venda com mais de 1 parcela.
			If nTotParc > 1     //.And. nParcela = 1
				For n := 1 to nTotParc

					If n = nTotParc
						nValParc := nTotbrut - nTotComp
						nValDes  := nTottx   - nTotDesc
					Else
						nValParc := nVlparc
						nValDes  := nValtx    //nValDesc

						nTotComp += nVlParc
						nTotDesc += nValTx
					Endif

					nValtx    := Round((nValbrut * nPerc)/100,2)
					nValliq   := nValbrut - nValtx
					nValtx    := 0 - nValtx

					dData   := dData + 30
					If n <> nParcela
						dDatapg := DataValida(dData)
					Else
						dDataPg := dDataPag
					EndIf

					//Tratamento de Parcela, informação origem do vetor vParc
					cParcela := vParc[n]
					nLeErro:=0

					//Gravação da Tabela SZF com a confirmação das Vendas Aprovadas pela Administradora.
					GeraSZF("A")
					If cBaixar .and. n <= nParcela
						//_lret := bx_resumo(cAdmin, cId, cCodAut, cResumo, cParcela)
					EndIf
				Next
			Else
				nLeErro :=0

				GeraSZF("A")
				If cBaixar
					//_lret := bx_resumo(cAdmin, cId, cCodAut, cResumo, cParcela)
				EndIf
			EndIf

			// Fim do Trecho incluido por Luzio

			//Gravação da Tabela SZF com a confirmação das Vendas Aprovadas pela Administradora.
			//  		GeraSZF("A")
			//	    	If cBaixar
			//  		   _lret := bx_resumo(cAdmin,cCodAut,cResumo, cParcela)
			//   		EndIf


			/*
		// ELO - 06.12.06 - Gera contas a receber a partir do SZF
		// REMOVIDO TEMPORARIAMENTE

		DBSELECTAREA("SE1");dbOrderNickName("PSE11")

		// Verifica se ja existem os títulos, e se existir gera LOG
		If SZF->ZF_TIPO=="CC" .AND. !SE1->(DbSeek(xFilial("SE1")+SZF->ZF_ADM+SZF->ZF_CODAUT+SZF->ZF_NUMCART+SZF->ZF_PARCELA))

		_cTitulo := U_PROXTIT()
		_cNatTit := Substr(Posicione("SX5",1,xFilial("SX5") + "ZM" + SZF->ZF_TIPO,"X5_DESCRI"),1,10)
		_cNatTit := Substr(_cNatTit,1,4)+"1"+Substr(_cNatTit,6,4)

		_aClienteLoja := getClienteLoja( SZF->ZF_PV )

		_aSE1 := { ;
		{ "E1_FILIAL",  xFilial( "SE1" ),               Nil }, ;
		{ "E1_PREFIXO", Substr(cTitulo,1,3),            Nil }, ;
		{ "E1_NUM",     Substr(cTitulo,4,6),            Nil }, ;
		{ "E1_PARCELA", SZF->ZF_PARCELA, 				Nil }, ;
		{ "E1_TIPO",    SZF->ZF_TIPO,                   Nil }, ;
		{ "E1_NATUREZ", _cNatTit,                       Nil }, ;
		{ "E1_CLIENTE", _aClienteLoja[1],               Nil }, ;
		{ "E1_LOJA",    _aClienteLoja[2],               Nil }, ;
		{ "E1_EMISSAO", SZF->ZF_DATAVEN,                Nil }, ;
		{ "E1_VENCTO",  SZF->ZF_DATAVEN,                Nil }, ;
		{ "E1_VENCREA", SZF->ZF_DATAVEN,                Nil }, ;
		{ "E1_VALOR",   SZF->ZF_VALBRUT,                Nil }, ;
		{ "E1_MOEDA",   1,                              Nil }, ;
		{ "E1_VLCRUZ",  SZF->ZF_VALBRUT,                Nil }, ;
		{ "E1_ADM",     SZF->ZF_ADM,                    Nil }, ;
		{ "E1_XRESUMO", SZF->ZF_RESUMO,                 Nil }, ;
		{ "E1_XAUTORI", SZF->ZF_CODAUT,                 Nil }, ;
		{ "E1_CARTAO",  SZF->ZF_NUMCART,                Nil }, ;
		{ "E1_XDTDIGI", dDatabase,                      Nil }, ;
		{ "E1_XORIGEM", "L",                            Nil }, ;
		{ "E1_XNUMPRC", VAL(SZF->ZF_PARCELA),           Nil }, ;
		{ "E1_FLUXO",   "S",                            Nil }, ;
		{ "E1_XTXCC",   SZF->ZF_VALTX,                  Nil }, ;
		{ "E1_XORIGEM", "L",                            Nil } }

		lMsErroAuto := .F.
		MSExecAuto( { | x, y | Fina040( x, y ) }, _aSE1, 3 ) //3-Inclusao  /5-Exclusao

		If lMsErroAuto
		// gera LOG de erro
		log_erro("Nao foi pussiver gerar o titulo!")
		Else  //ElseIf SE1->(DbSeek(xFilial("SE1")+SZF->ZF_ADM+SZF->ZF_CODAUT+SZF->ZF_NUMCART+SZF->ZF_PARCELA))
		//						RecLock("SE1",.F.)
		//						SE1->E1_XTXCC := SZF->ZF_VALTX
		//						MsUnLock()
		//	RecLock("SZF",.F.)
		//	SZF->ZF_STATUS  := "B"
		//	MsUnLock()
		Endif

		Else
		If SE1->E1_TIPO=="CC"
		LOG_ERR("TITULO CC JA EXISTENTE")
		ElseIf SE1->E1_TIPO=="CD" .AND. SE1->E1_SALDO==0
		LOG_ERR("TITULO CD JA BAIXADO")
		Else
		//					_lret := bx_tit_rec(SZF->ZF_ADM,SZF->ZF_CODAUT,SZF->ZF_NUMCART,SZF->ZF_PARCELA,cId)
		Endif
		Endif

			*/

		Else

			// nLeErro++

		Endif

		if nLeErro > 10
			//		u_log_erro("Erro ao ler o aquivo >> " + Alltrim(cFile))
			nErros++
			//		exit
			//		Comentado por Marcos Furtado - 11/12/13. Não se pode garantir que não vira linhas válidas após 10 linhas desconsideradas.
		endif

		//	DbSkip()
		FT_FSKIP()

	EndDo

	// Gera Titulo de Aluguel de POS, caso exista
	If len(_aPos)>0
		gerapos(_apos)
	Endif

	//DbSelectArea("VISA")
	//DbCloseArea()

	FT_FUSE()

Return()

/**************************************************************************
* Programa....: HiperCard                                                 *
* Autor.......: 			                                              *
* Finalidade..: Leitura do arquivo txt dos cartões de Crédito HiperCard   *
* ............: para a alimentação da tabela de Movimento de Cartões      *
* Data........:                                                           *
**************************************************************************/

Static Function HiperCard()
	Local n
	Private _cBand := "Hipercard"

	// 02=Serasa;07=Ajustes;12=POS;14=Liquidacao;36=Antecipacao;40=Cancelamento;42=Venda

	_cEmpZF  := "  "
	_cFilZF  := "  "
	cPv      := ""
	cAdmin   := "13"
	vVettxt  := {}
	cBaixar  := .f.

	nTotParc := 0
	nVlparc  := 0
	nValParc := 0
	nTotComp := 0
	nValDesc := 0
	nValDes  := 0
	nTotDesc := 0
	nTotLiq  := 0
	nParcela := 0
	nTotDesc := 0
	nTotBrut := 0
	nTotTx := 0

	ReiniciaVar()
	nLeErro  := 0

	cAdmOri	 := ""
	cNoPOS   := ""



	/********************************
* Criacao de Tabela temporaria. *
	********************************/
	/*
aAdd(vVettxt,{"cBuffer","C",500,0})

cArqvettxt := CriaTrab(vVettxt, .T.)
dbUseArea(.T.,,cArqvettxt,"HiperCard",.F.)
dbSelectArea("HiperCard")
Append From (cFile) SDF

dbGoTop()

//          1         2         3         4         5         6         7         8         9         0         1         2         3         4         5         6         7         8         9         0         1         2         3
// 1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345
// 000000102962007090420070904200709040000160HIPERCARD002.03
// 10017100243213000932906/09PAG20070309200709032007090620070906+0000000087939+0000000000000+000000000977100400+000000000039000000+0000000000000+0000000009381+00000000000000422000060000037518    00001 000000000007R2P+0000+0000+0000+0000
// 200171002432130009329      124208142601220070309+0000000087939+0000000009771+0000000000000                              076181861532ELEONL510441610010000007+0000000009771+0000000009381PRC+0000000009381
// 10017300054205001850700/00PRE20070903000000002007100400000000+0000000004400+0000000000000+000000000440000300+000000000013200000+0000000000000+0000000004268+00000000000000422000060000037522    00001 000000000002R2U+0000+0000+0000+0000
// 200173000542050018507      148178812103420070719+0000000004400+0000000004400+0000000000000                              056757078327ELEOFF510861970010000002+0000000004400+0000000004268PRC+0000000004268
// 100164022089990000000     TAR00000000000000000000000020070906-0000000001920+0000000000000+000000000000000000+000000000000000000+0000000000000-0000000001920+00000000000000422000060000037517    00040 000000000000R0 +0000+0000+0000+0000
// 70016402208999000000020070906200709-0000001920POS
// 900000000002

While !Eof()
	*/

	FT_FGOTOP()

	While ( ! FT_FEOF() )
		//Peder Munksgaard - 11/07/2018
		//Correção do problema de codepage que ocorria devido a
		//palavra comissão.
		//cBuffer := AllTrim(FT_FREADLN())
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		//
		/************************************
	* Trecho para a manipulacao do TXT. *
		************************************/

		If Substr(cBuffer,1,1) == '0'

			_cEmpZF := ""
			_cFilZF := ""
			//[BRUNO:25/10/2011]
			//cPv      := Substr(cBuffer,02,10)       // ponto de venda
			nLeErro:=0

			_cEmpZF := "" //TP4->PA4_CODEMP
			_cFilZF := "" //TP4->PA4_CODFIL


		ElseIf Substr(cBuffer,1,1) == '1'

			cTotParc := Substr(cBuffer,25,2)
			cBanco   := Alltrim(Padr(Alltrim(Strzero(Val(Substr(cBuffer,170,04)),03)),03))
			cAgencia := StrZero(Val(Alltrim(Padr(Alltrim(Strzero(Val(Substr(cBuffer,174,05)),05)),05))),4)
			cConta   := Alltrim(Padr(Alltrim(Str(Val(Substr(cBuffer,179,14)))),10))
			dDataPag  := stod(Substr(cBuffer,46,08))   // Formato da data AAAAMMDD

			nValtx1  := ( Val(Substr(cBuffer,104,5))/100)  //00400
			//		if Substr(cBuffer,109,1) == "+"   // Comentado por Luzio para manter o valor da taxa positivo
			if Substr(cBuffer,109,1) == "-"
				nValtx1  := nValtx1 * -1
			endif

			nValtx2  := ( Val(Substr(cBuffer,123,5))/100)  //00000
			if Substr(cBuffer,128,1) == "-"
				nValtx2  := nValtx2 * -1
			endif

			//  		nValRej := Val(Substr(cBuffer,77,14))
			nValRej := ( Val(Substr(cBuffer,77,13))/100 )
			if Substr(cBuffer,76,1) == "-"
				nValRej  := nValRej * -1
			endif

			If Substr(cBuffer,22,2) == '00' .or. Empty(Substr(cBuffer,22,2))
				cParcela := vParc[1]
				nParcela := 1
			Else
				cParcela := vParc[Val(Substr(cBuffer,22,2))]
				nParcela := Val(Substr(cBuffer,22,2))
			EndIf

			nLeErro:=0

			If Substr(cBuffer,27,3) == 'PRE'  //PREVISAO DE PAGAMENTO

				cBaixar := .f.
				cId      := '14' // TIPO DE OPERACAO = VENDA
				cTipo    := 'CC' // PREVISAO DE VENDA = CREDITO ( CC )
				cDescric := 'PREVISAO HIPERCARD'
				dData   := stod(Substr(cBuffer,30,08))   // Formato da data AAAAMMDD
				cResumo  := Substr(cBuffer,15,07)

				// Incluido pelo Luzio
				//			nValbrut := val(Substr(cBuffer,64,13))/100       //0000000087939  //63,13
				// 			nValLiq  := val(substr(cBuffer,143,13))/100

			ElseIf Substr(cBuffer,27,3) == 'AJU'  //AJUSTES

				cBaixar := .f.
				cId      := '07' // TIPO DE OPERACAO = AJUSTES
				cTipo    := 'CC' // PREVISAO DE VENDA = CREDITO ( CC )
				cDescric := 'AJUSTE HIPERCARD'
				cResumo  := Substr(cBuffer,15,07)
				nLeErro:=0

			ElseIf Substr(cBuffer,27,3) == 'PAG'  //PAGAMENTO = LIQUIDACAO

				cBaixar := .t.
				cId      := '14' // TIPO DE OPERACAO = LIQUIDACAO
				cTipo    := 'CC' // PAGAMENTO = CREDITO ( CC )
				cDescric := 'LIQUIDACAO HIPERCARD'
				dData    := stod(Substr(cBuffer,30,08))

				// Alterado por Luzio para armazenar o valor real e nao inteiro
				//			nValbrut := val(Substr(cBuffer,63,13))/100  //0000000087939
				//			nValbrut := val(Substr(cBuffer,64,13))/100  //0000000087939
				//			nValLiq  := val(substr(cBuffer,143,13))/100

				cResumo  := Substr(cBuffer,15,07)

			ElseIf Substr(cBuffer,27,3) == 'TAR'  //TARIFAS

				cBaixar := .f.
				cId      := '12' // TIPO DE OPERACAO = POS
				cTipo    := 'CC' // PREVISAO DE VENDA = CREDITO ( CC )
				cDescric := 'TARIFA HIPERCARD'
				cResumo  := Substr(cBuffer,15,07)
				nLeErro:=0
				nValBrut := val(substr(cBuffer,39,13))/100
				nValLiq  := val(substr(cBuffer,143,13))/100
				nValTx   := 0
				dDataPG  := stod(Substr(cBuffer,54,8))
				dDataVen := ddatabase
				cCartao  := " "
				cCodAut  := " "
				cParcela := "  "
				//			GeraSZF("C")
				//GeraSZF("B")

			ElseIf Substr(cBuffer,27,3) == 'ANT'  //PAGAMENTO ANTECIPADO

				cBaixar := .f.
				cId      := '14' // TIPO DE OPERACAO = AJUSTES
				cTipo    := 'CC' // PREVISAO DE VENDA = CREDITO ( CC ).
				cDescric := 'LIQUID. ANT. HIPERCARD'
				dData   := stod(Substr(cBuffer,54,08))

				// Comentado por Luzio para que considere o valor real e nao o inteiro do arquivo
				//			nValbrut := val(Substr(cBuffer,63,13))
				nValbrut := val(Substr(cBuffer,63,13))/100

				cResumo  := Substr(cBuffer,15,07)
				nLeErro:=0

			ElseIf Substr(cBuffer,27,3) == 'DES'  //PAGAMENTO ANTECIPADO

				cBaixar := .f.
				cId      := '07' // TIPO DE OPERACAO = CANCELAMENTO
				cTipo    := 'CC' // DESAGENDAMENTO = CANCELAMENTO DE PARCELAS ( CC )
				cDescric := 'CANCELAMENTO HIPERCARD'
				cResumo  := Substr(cBuffer,15,07)
				nLeErro:=0

			EndIf

		ElseIf Substr(cBuffer,1,1) == '2'

			if cDescric == "LIQUIDACAO HIPERCARD"
				FT_FSKIP()
				loop
			endif

			nVlparc  := 0
			nValParc := 0
			nTotComp := 0
			nTotDesc := 0
			nValDesc := 0
			nValDes  := 0
			nTotBrut := 0
			nTotTx   := 0
			//[BRUNO:25/10/2011] PV
			cPv      := Substr(cBuffer,02,10)       // ponto de venda
			cResumo  := Substr(cBuffer,15,07)
			cCartao  := alltrim(Substr(cBuffer,22,19))
			dDataven := stod(Substr(cBuffer,41,08))       // Formato da data AAAAMMDD
			cCodAut  := Substr(cBuffer,121,6)             //Autorização
			nValbrut := val(Substr(cBuffer,50,13))/100    //50,13))
			nTotBrut := val(Substr(cBuffer,50,13))/100    //50,13))

			//nTotParc := Val(Substr(cBuffer,25,2))
			nTotParc := Val(cTotParc)
			nVlParc  := val(Substr(cBuffer,64,13))/100

			//[BRUNO:29/11/2010 - Pegar numero de POS(maquineta)
			cNoPos	 := Substr(cBuffer,139,8)

			/*
		If nTotParc > 15
			//			lerLinha(nHdl)
			FT_FSKIP()
			Loop
		EndIf
			*/

			if nTotParc = 0
				nTotParc:= 1
				cTotParc:= "01"
			endif

			//		If nTotParc > 0
			//			nVlParc := nValbrut / nTotParc
			//		Else
			//			nVlParc := nValbrut
			//		Endif

			nValRej  := val(Substr(cBuffer,77,13))/100
			nTotTx   := ((nValbrut * nValtx2)/100) + ((nValbrut * nValtx1)/100)
			nTotTx   := 0 - nTotTx
			nValTx   := ((nVlParc * nValtx2)/100) + ((nVlParc * nValtx1)/100)
			//		nValliq  := nValbrut - nTotTx  - nValRej
			nValliq  := nVlParc - nValTx - nValRej
			nValtx   := 0 - nValTx
			nValdesc := nValTx

			/*
		If nTotParc ==  0 .OR. nTotParc == 1
		dData   := dData + 30
		dDatapg := dData
		//			GeraSZF(iif("PREVISAO"$cDescric,"A","C"))
		GeraSZF(iif("PREVISAO"$cDescric,"A","B"))
		//			lerLinha(nHdl)
		FT_FSKIP()
		Loop
		EndIf
			*/

			For n := 1 to nTotParc

				If n = nTotParc
					nValParc := nTotBrut - nTotComp
					nValDes  := nTottx   - nTotDesc
				Else
					nValParc := nVlparc
					nValDes  := nValTx

					nTotComp += nVlParc
					nTotDesc += nValTx
				Endif

				nValbrut := nValParc
				nValtx   := nValDes
				nValliq  := nVlParc - abs(nValTx) - abs(nValRej)

				dData   := dData + 30
				If n <> nParcela
					dDatapg := DataValida(dData)
				Else
					dDataPg := dDataPag
				EndIf

				//Tratamento de Parcela, informação origem do vetor vParc
				cParcela := vParc[n]
				nLeErro := 0
				//Gravação da Tabela SZF com a confirmação das Vendas Aprovadas pela Administradora.
				//		        GeraSZF(iif("PREVISAO"$cDescric,"A","C"))
				GeraSZF(iif("PREVISAO"$cDescric,"A","B"))
				//   			If cBaixar .and. n <= nParcela .and. "LIQUIDACAO" $ cDescric
				//      			_lret := bx_resumo(cAdmin, cId, cCodAut, cResumo, cParcela)
				//  	    	EndIf

			Next

		ElseIf Substr(cBuffer,1,1) == '3'

			//previsoes de pagamento
			nLeErro := 0

		ElseIf Substr(cBuffer,1,1) == '4'

			cResumo  := Substr(cBuffer,15,07)
			nLeErro := 0

		ElseIf Substr(cBuffer,1,1) == '5'

			cResumo  := Substr(cBuffer,15,07)
			cCartao  := alltrim(Substr(cBuffer,22,19))
			//dDatapg := stod(Substr(cBuffer,49,08))
			cCodAut  := Substr(cBuffer,103,3) //Autorização
			dData   := dDataven
			nValbrut := val(Substr(cBuffer,66,13))
			if Substr(cBuffer,65,1) =='-'
				nValbrut := nValbrut * -1
			endif
			nValliq  :=val(Substr(cBuffer,80,13))
			if Substr(cBuffer,79,1) =='-'
				nValliq := nValliq * -1
			endif
			cCodAut  := Substr(cBuffer,103,3) //Autorização
			//nTotParc:= Val(cTotParc)
			nLeErro := 0
		ElseIf Substr(cBuffer,1,1) == '7'
			cResumo  := Substr(cBuffer,15,07)
			nLeErro := 0
		Else
			nLeErro++
		EndIf

		if nLeErro > 10
			//		u_log_erro("Erro ao ler o aquivo >> " + Alltrim(cFile))
			nErros++
			//		exit
			//		Comentado por Marcos Furtado - 11/12/13. Não se pode garantir que não vira linhas válidas após 10 linhas desconsideradas.
		endif
		FT_FSKIP()
		//	DbSkip()
	EndDo

	//DbSelectArea("HiperCard")
	//DbCloseArea()
	FT_FUSE()

Return()

/***************************************************************************
* Programa....: RedCard                                                    *
* Finalidade..: Leitura do arquivo txt dos cartões de Crédito RedCard para *
*                a alimentação da tabela de Movimento de Cartões.          *
* Data........: 06/03/06                                                   *
***************************************************************************/

Static Function AMEX()
	Private _cBand := "AMEX"
	Private _aPos := {}

	//Reinicia Variáveis
	cTpPag  := ""
	cAdmin  := "10"
	_cEmpZF := "  "
	_cFilZF := "  "
	vVettxt := {}
	cResumo  := ""
	cCartao  := ""
	cCodAut  := ""
	cParcela := "  "
	cTotParc := "  "
	cId      := ""
	cBanco   := ""
	cAgencia := ""
	cConta   := ""
	cTipo    := "CC"
	cPv      := ""
	cDescric := ""
	dDatapg  := ""
	dDataven := ""
	nValliq  := 0
	nValbrut := 0
	nValtx   := 0
	nTotParc := 0
	nVlparc  := 0
	nValParc := 0
	nTotComp := 0
	nValDesc := 0
	nValDes  := 0
	nTotDesc := 0
	nLeErro  := 0

	cAdmOri	 := ""
	cNoPOS   := ""


	/********************************
* Criacao de Tabela temporaria. *
	********************************/
	/*
aAdd(vVettxt,{"cBuffer","C",500,0})

cArqvettxt := CriaTrab(vVettxt, .T.)
dbUseArea(.T.,,cArqvettxt,"'",.F.)
dbSelectArea("AMEX")
Append From (cFile) SDF

dbGoTop()

While !Eof()
_cBuf1 := Left(AMEX->CBUFFER,48)
_cBuf2 := Substr(AMEX->CBUFFER,49,len(AMEX->CBUFFER))
	*/

	FT_FGOTOP()

	While ( ! FT_FEOF() )
		//Peder Munksgaard - 11/07/2018
		//Correção do problema de codepage que ocorria devido a
		//palavra comissão.
		//cBuffer := AllTrim(FT_FREADLN())
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		//

		_cBuf1 := Left(cBuffer,48)
		_cBuf2 := Substr(cBuffer,49,len(cBuffer))

		If Substr(_cBuf1,45,1) == "0"  // cabecalho
			//[BRUNO:25/10/2011]
			//cPv     := Alltrim(Substr(_cBuf1,1,10))

			nLeErro:=0

			_cEmpZF := ""
			_cFilZF := ""

			// PEGA DADOS DO CABECALHO GERAL DA LOJA
		ElseIf Substr(_cBuf1,45,1) == "1"

			le_buf(_cBuf2,_cBuf1)
			/*
		// Ignora PAGAMENTOS FUTUROS
		If cTpPag=="P"
		//			u_log_erro("PV "+Alltrim(cPV)+" nao cadastrada na tabela "+retsqlname("PA4"))
		//			dbSelectArea("AMEX")
		//			dbskip()
		//			Do While !AMEX->(EOF()) .and. Substr(AMEX->CBUFFER,45,1) <> "0"
		//				dbskip()
		//			Enddo

		FT_FSKIP()

		//Peder Munksgaard - 11/07/2018
		//Correção do problema de codepage que ocorria devido a
		//palavra comissão.
		//cBuffer := AllTrim(FT_FREADLN())
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		//

		_cBuf1 := Left(cBuffer,48)
		_cBuf2 := Substr(cBuffer,49,len(cBuffer))

		While ( ! FT_FEOF() ) .and. Substr(_cBuf1,45,1) <> "0" .and. Substr(_cBuf1,45,1) <> "1"
		FT_FSKIP()

		//Peder Munksgaard - 11/07/2018
		//Correção do problema de codepage que ocorria devido a
		//palavra comissão.
		//cBuffer := AllTrim(FT_FREADLN())
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		//

		_cBuf1 := Left(cBuffer,48)
		_cBuf2 := Substr(cBuffer,49,len(cBuffer))
		Enddo
		loop
		Endif
			*/
			//PEGA DADOS DO PAGAMENTO
		ElseIf Substr(_cBuf1,45,1) $ "3/4"

			le_buf(_cBuf2,_cBuf1)

			If Substr(_cBuf1,45,1)=="4"
				//			GeraSZF("C")
				GeraSZF("B")
			Endif

			// AJUSTES E ALUGUEL DE POS
		ElseIf Substr(_cBuf1,45,1) == "5"

			le_buf(_cBuf2,_cBuf1)

			If cId=="07"

				GrvAjuste("A")

			EndIf

			nLeErro := 0

		Elseif  Substr(_cBuf1,45,1) == "9"

			FT_FSKIP()

			loop

		Else

			nLeErro++

		EndIf

		If nLeErro > 10
			//		u_log_erro("Erro ao ler o aquivo >> " + Alltrim(cFile))
			nErros++
			//		exit
			//		Comentado por Marcos Furtado - 11/12/13. Não se pode garantir que não vira linhas válidas após 10 linhas desconsideradas.
		Endif
		//	dbskip()
		FT_FSKIP()

	EndDo


	//DbSelectArea("AMEX")
	//DbCloseArea()
	FT_FUSE()

Return()


/***************************************************************************
* Programa....: Blu	                                                       *
* Finalidade..: Leitura do arquivo CSV dos cartões administrados pela BLU  *
* Autor: Adriano Dourado                                                   *
* Data........: 25/07/18                                                   *
***************************************************************************/
**********************
Static Function BLU()
	**********************

	Local n
	Local cQry := ""
	Local cPA7empres
	Local _aAreaPA7 := GetArea()
	Local _aTmpPA7  := {}
	Private _cBand := "BLU"
	Private _aPos := {}
	cAdmin   := "44"

	cQry := "SELECT '44' AS PA7_ADM,
	cQry += "       BLU_ID AS PA7_AUTORI,
	cQry += "       CHARGE_ID AS PA7_CARTAO,
	cQry += "       PAID_AT AS PA7_DTVEND,
	cQry += "       INSTALLMENTS AS PA7_TOTPAR,
	cQry += "       GROSS_VALUE AS PA7_VALOR,
	cQry += "       CHARGED AS PA7_PV,
	cQry += "       CNPJ AS PA7_DESCRI,
	cQry += "       PAID_AT AS PA7_RESUMO,
	cQry += "       DT_DEVCOB AS PA7_DTCANC,
	cQry += "       DEV_VALUE AS PA7_VLCANC,
	cQry += "       BLU_UUIDPARC AS PA7_NOMARQ
	cQry += "  FROM SIGA.TRANSACAOBLU TB
	cQry += "  LEFT JOIN SIGA.PA7030 A7 ON PA7_ADM = '44'
	cQry += "                       AND PA7_AUTORI = BLU_ID
	If cEmpAnt == '18' .AND. cFilAnt == "03"
		cQry += " WHERE UN = '27'
	ElseIf cEmpAnt == '18' .AND. cFilAnt == "04"
		cQry += " WHERE UN = '28'
	Else
		cQry += " WHERE UN = '"+cEmpAnt+"'
	Endif
	// cQry += "   AND ORIGEM = 'C' AND A7.PA7_AUTORI IS NULL
	cQry += "   AND ORIGEM IN ('C','P') AND A7.PA7_AUTORI IS NULL
	cQry += " ORDER BY PAID_AT DESC

	U_ORTQUERY(cQry,"BLUAPI","ORTA023D_BLUAPI.sql")

	WHILE !BLUAPI->(EOF())


		c_campo1 := BLUAPI->PA7_AUTORI			// IDTRANSAÇÃO
		c_campo2 := BLUAPI->PA7_CARTAO			// IDCOBRANÇA
		c_campo3 := BLUAPI->PA7_PV		// NUMPEDIDO
		c_campo4 := BLUAPI->PA7_VALOR// VALOR PARCELA
		c_campo5 := StoD(BLUAPI->PA7_DTVEND)	// DT PAGAMENTO PEDIDO
		c_campo6 := Stod(BLUAPI->PA7_RESUMO) // dt liberacao do pagamento
		c_campo7 := BLUAPI->PA7_TOTPAR			// NUM. PARCELA
		c_campo8 := BLUAPI->PA7_DESCRI			// CNPJ CLIENTE
		c_campo9 := ''		// NOME CLIENTE
		c_campo10:= ''		// CNPJ UNIDADE ORTO
		c_campo11:= ''		// RAZAO SOCIAL UNIDADE

		if !empty(BLUAPI->PA7_DTCANC)
			c_campo12:= BLUAPI->PA7_DTCANC	// DATA_CANCELAMENTO_POS_OU_COBRANCA
		Else
			c_campo12:= Stod(" ")
		EndIf
		// Joni Fujiyama - 16/12/2019
		if !empty(BLUAPI->PA7_VLCANC)
			c_campo13:= BLUAPI->PA7_VLCANC	// VALOR_CANCELAMENTO_POS_OU_COBRANCA
		Else
			c_campo13:= 0.00
		EndIf
		c_campo14 := Alltrim(BLUAPI->PA7_NOMARQ)

		AADD(_aTmpPA7,{c_campo1,c_campo2,c_campo3,c_campo4,c_campo5,c_campo6,c_campo7,c_campo8,c_campo9,c_campo10,c_campo11,c_campo12,c_campo13,c_campo14})  // Joni Fujiyama - 16/12/2019

		BLUAPI->(DbSkip())
	End

	BLUAPI->(DbCloseArea())
	RestArea(_aAreaPA7)

	nLeErro := 0

	For n := 1 to len(_aTmpPA7)


		cPA7empres:= cEmpAnt

		cQry := " SELECT R_E_C_N_O_ "
		cQry += "   FROM PA7030 "
		cQry += "  WHERE D_E_L_E_T_ = ' ' "
		cQry += "    AND PA7_ADM    = '44' "
		cQry += "    AND PA7_AUTORI = '"+_aTmpPA7[n,1]+"' "
		cQry += "    AND PA7_CARTAO = '"+_aTmpPA7[n,2]+"' "

		IF SELECT("TMPPA7") > 0
			DBSELECTAREA("TMPPA7")
			DBCLOSEAREA()
		ENDIF

		U_ORTQUERY(cQry,"TMPPA7","ORTA023D_TMPPA7_A.sql")

		DbSelectArea("TMPPA7")

		If !(TMPPA7->(EOF()))
			Conout("ORTA023D - AMBIENTE: "+upper(alltrim(GetEnvServer()))+" - Pedido: "+_aTmpPA7[n,3]+" já lançado, verificar.")
			nLeErro++
			Loop
		Endif

		If cPA7empres == '02'
			If _aTmpPA7[n,5] < CtoD("01/08/18")
				Conout("ORTA023D - AMBIENTE: "+upper(alltrim(GetEnvServer()))+" - Pedido: "+_aTmpPA7[n,3]+" com data anterior a data de corte, verificar.")
				nLeErro++
				Loop
			Endif
		Endif

		If cPA7empres == '07'
			If _aTmpPA7[n,5] < CtoD("30/07/18")
				Conout("ORTA023D - AMBIENTE: "+upper(alltrim(GetEnvServer()))+" - Pedido: "+_aTmpPA7[n,3]+" com data anterior a data de corte, verificar.")
				nLeErro++
				Loop
			Endif
		Endif

		TMPPA7->(DBCLOSEAREA())

		DbSelectArea("PA7")

		TcRefresh(RetSqlName("PA7"))

		PA7->(RecLock("PA7",.T.))

		PA7_ADM   := cAdmin
		PA7_ADMORI:= "44"
		PA7_AUTORI:= _aTmpPA7[n,1]
		PA7_CARTAO:= _aTmpPA7[n,2]
		PA7_PV    := _aTmpPA7[n,3]
		//PA7_NOMARQ:= "CONSULTA API"
		PA7_VALOR := _aTmpPA7[n,4]
		PA7_DTVEND:= _aTmpPA7[n,5]
		PA7_RESUMO:= Substr(DtoS(_aTmpPA7[n,6]),1,4)+Substr(DtoS(_aTmpPA7[n,6]),5,2)+Substr(DtoS(_aTmpPA7[n,6]),7,2)
		PA7_DESCRI:= _aTmpPA7[n,8]
		PA7_EMPRES:= cPA7empres
		PA7_TOTPAR:= "1"
		PA7_DTCANC:= _aTmpPA7[n,12]
		PA7_VLCANC:= _aTmpPA7[n,13]
		PA7_NOMARQ:= _aTmpPA7[n,14]

		PA7->(MsUnlock())
		TcRefresh(RetSqlName("PA7")) // Andre Carralero - 01/10/2024
	Next

	FT_FUSE()

Return()

***************************************************************************
* Programa....: GeraSZF                                                   *
* Autor.......: Rafael Melo                                               *
* Finalidade..: Gravação da Tabela SZF - Movimento de Cartões.            *
* Data........: 03/03/06                                                  *
***************************************************************************
Static Function GeraSZF(_cStat)
	***************************************************************************

	Local aArea := GetArea()

	//DbSelectArea("SZF")
	//DbSetOrder(1)
	//DbGoTop()
	dbSelectArea("PA4")
	dbOrderNickName("CPA41")

	area6 := getarea()

	cArquivo:= cFile
	nPos     := RAT("\",cArquivo)
	cArquivo := Substr(cArquivo,nPos+1)

	//cArquivo:= cFile
	//nPos     := RAT("\",cArquivo)
	//cArquivo := Substr(cArquivo,nPos+1)
	//MSPROCTXT(cArquivo + " / Reg Processados: " + alltrim(str(nReg)))


	//[BRUNO:24/11/2010] -- INSERIR EM NOVA TABELA.

	//Início SSI 15976
	If cAdmin == "15" .OR. cAdmin == "23" .OR. cAdmin == "24"
		nPosPa7:= aScan(aRegPA7,{|x| alltrim(x[1])== Alltrim(cAdmin) .AND. alltrim(x[2])== Alltrim(cCodAut) .AND.;
			alltrim(x[3])== Alltrim(cCartao) .AND. alltrim(x[4])== Alltrim(cPv).AND.;
			alltrim(x[5])== Alltrim(cArquivo) .AND. alltrim(x[6]) == Alltrim(dDataven)})
	Else
		//Fim SSi 15976
		nPosPa7:= aScan(aRegPA7,{|x| alltrim(x[1])== Alltrim(cAdmin) .AND. alltrim(x[2])== Alltrim(cCodAut) .AND.;
			alltrim(x[3])== Alltrim(cCartao) .AND. alltrim(x[4])== Alltrim(cPv).AND.;
			alltrim(x[5])== Alltrim(cArquivo) .AND. alltrim(x[6]) == Alltrim(dDataven) .AND.;
			alltrim(x[7])== Alltrim(cTotParc) })
	EndIf //SSI 15976



	//alert(Alltrim(cArquivo))

	//alert(dDataven)

	if nPosPa7 = 0
		aAdd(aRegPA7,{cAdmin,;	    	//1 Adm Captura
			cCodAut,;     //2  Codigo de Autorização
			AllTrim(cCartao),;    //3  Numero de Cartao
			cPv,;		   //4  Ponto de Venda
			cArquivo,;	   //5	Arquivo de Importaçãp
			dDataven,;	   //6  Data da Venda
			cTotParc,;	   //7  Parcelas
			IIF(cAdmin == "17",nVlParc,nValbrut),;   //8	Valor Total de Parcelas
			cAdmOri,;           //9   Adm Origem
			cNoPos,;			  //10  No POS(Maquineta)
			cDescric,;		  //11  Descricao da Operacao da Administradora
			cResumo})	  //12 Resumo

	elseif nPosPa7 > 0  .and. aRegPA7[nPosPA7,1] <> "10"
		If aRegPA7[nPosPA7,1] == "17" //Adicionado em 03/04/2013 - Furtado - O Banese enviar todas as parcelas.
			aRegPA7[nPosPA7,8]:= aRegPA7[nPosPA7,8] + nVlParc
		ElseIf aRegPA7[nPosPA7,1] == "15" .OR. aRegPA7[nPosPA7,1] == "23" .OR. aRegPA7[nPosPA7,1] == "24" //SSI 15976
			aRegPA7[nPosPA7,7]:= cTotParc //SSI 15976
		Else
			aRegPA7[nPosPA7,8]:= aRegPA7[nPosPA7,8] + nValbrut
		Endif
	endif
	//FIM.[BRUNO:24/11/2010]

	nReg++
	RestArea(aArea)
	//ReiniciaVar()
Return()

***************************************************************************
* Programa....: Arruma                                                    *
* Autor.......: Rafael Melo                                               *
* Finalidade..: Função para arrumacao dos campos separados por virgula.   *
* Data........: 21/02/06                                                  *
***************************************************************************
Static Function Arruma()
	***************************************************************************

	//ÚÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ¿
	//³Declaração de Variáveis³
	//ÀÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÙ

	Local cCampo, i

	For i := 1 to 20
		cCampo      := "cCampo"+StrZero(i,2)
		//	&cCampo     := AllTrim(substr(TXT->CAMPOS,1,If(at(',',TXT->CAMPOS) > 0,at(',',TXT->CAMPOS)-1,Len(TXT->CAMPOS))))
		&cCampo := AllTrim(substr(cBuffer,1,If(at(',',cBuffer) > 0,at(',',cBuffer)-1,Len(cBuffer))))
		//	TXT->CAMPOS := substr(TXT->CAMPOS,at(',',TXT->CAMPOS)+1)
		cBuffer := substr(cBuffer,at(',',cBuffer)+1)
	Next

Return()

static function lerLinha(nHdl)
	cBuffer2 := ""
	cBuffer := ""
	nBtLidos := fRead(nHdl,@cBuffer2,1)
	while cBuffer2 <> CHR(13)  .AND. nBtLidos > 0
		cBuffer := cBuffer + cBuffer2
		nBtLidos := fRead(nHdl,@cBuffer2,1)
	enddo
	nBtLidos := fRead(nHdl,@cBuffer2,1) // pula o chr(10)
return()

Static Function ReiniciaVar()
	//Reinicia Variáveis
	cResumo  := ""
	cCartao  := ""
	cCodAut  := ""
	cParcela := "  "
	cTotParc := "  "
	nParcela := 0
	cDescric := ""
	cBanco   := ""
	cAgencia := ""
	cConta   := ""
	cTipo    := ""
	cId      := ""
	dDataven := stod("")
	dDatapg  := stod("")
	dData    := stod("")
	nValliq1 := 0
	nValbrut1:= 0
	nValtx1  := 0
	nValtx2  := 0
	nTotTx := 0
	nValliq  := 0
	nValbrut := 0
	nPerc    := 0
	nValRej := 0
	cTotParc := "  "
	nTamLin := 1
	nTotComp := 0
	nTotDesc := 0
	//nTotBrut := 0
	nTotTx := 0

return()

// Baixa de Titulos recebidos por Resumo
static function bx_resumo(_cAdmin, _cId, _cCodAut, _cResumo, _cParcela)
	Local _cQry
	Local _aAreaBXT := GetArea()

	// caso haja mais de um registro no arquivo TXT com o resumo repitido, não efetua a baixa novamente.
	// As baixas serão efetuadas dentro de uma unica transação, para que caso haja problema em alguma,
	// não seja efetuada a baixa de nenhuma!
	//If ascan(_atitbx,_cResumo)==0

	aadd(_aTitBX,_cResumo)

	// busca no SZF os titulos referente ao resumo
	_cqry := " SELECT R_E_C_N_O_ NUMREG FROM " + RetSqlName("SZF")
	_cqry += " WHERE D_E_L_E_T_<> '*'"
	_cqry += " AND ZF_FILIAL = '"+ xFilial("SZF") +"'"
	_cqry += " AND ZF_ADM = '"+_cAdmin+"'"
	_cqry += " AND ZF_RESUMO = '"+_cResumo+"'"
	_cqry += " AND ZF_ID = '"+_cId+"'"
	_cqry += " AND ZF_PARCELA = '"+ _cParcela +"'"
	If !Empty(_cCodAut) .and. _cCodAut <> NIL
		_cqry += " AND ZF_CODAUT = '"+ _cCodAut +"'"
	EndIf
	_cqry += " AND ZF_STATUS IN ('A')"
	_cqry += " ORDER BY ZF_FILIAL, ZF_PV, ZF_NUMCART, ZF_CODAUT"

	U_ORTQUERY(_cqry,"TZF","ORTA023D_TZF.sql")

	DbSelectArea("TZF")

	// caso nao encontre registro no SZF referente ao resumo, grava log de erro.
	If TZF->(EOF())
		TZF->(DBCLOSEAREA())
		//	u_log_erro("Nao foi encontrado registro na tabela SZF ref. ao resumo "+_cResumo )
		RestArea(_aAreaBXT)
		Return(.f.)
	Endif

	// Posiciona no SZF
	BEGIN TRANSACTION
		Do While !TZF->(EOF())
			DBSELECTAREA("SZF")
			SZF->(DBGOTO(TZF->NUMREG))
			RecLock("SZF")
			//		SZF->ZF_STATUS := "C"
			SZF->ZF_STATUS := "B"
			SZF->(MsUnlock())
			TZF->(DBSKIP())
		Enddo

	END TRANSACTION

	TZF->(dbCloseArea())

	//Endif

	RestArea(_aAreaBXT)

Return(.t.)

// Gera Titulo de POS/Extrato

Static Function gerapos(_aPos)
	Local _nPos := 1

	For _nPos := 1 to len(_aPos)

		cId      := _aPos[_npos,9]
		cResumo  := _aPos[_npos,3]
		dDataven := dDataBase // _aPos[_npos,4]
		dDataPg  := dDataBase //_aPos[_npos,5]
		//				dDataPg  := stod(Substr(cBuffer,45,06))
		nValliq  := _aPos[_npos,2]
		nValbrut := _aPos[_npos,2]
		nValtx   := 0
		cDescric := Iif(_aPos[_npos,9]=="02","TARIFA DE EXTRATO","ALUGUEL DE POS")
		cBanco   := _aPos[_npos,6]
		cAgencia := _aPos[_npos,7]
		cConta   := _aPos[_npos,8]
		cCartao  := ''
		cCodAut  := ''
		cParcela := '  '
		cTotParc := '  '
		cTipo    := ''

		//Gravação da Tabela SZF com a confirmação das Vendas Aprovadas pela Administradora.
		GeraSZF("A")
		/*
	// Gera e baixa titulo de pos
	_lRet := bx_tit_pos()
	If !_lRet
	DisarmTransaction()
	log_err()
	Endif
		*/
	Next
Return

// Rotina que le o resto do buffer da AMEX e retorna as variaves corretas
Static Function le_buf(_cVal,_cVal2)
	Local _nB := len(_cVal)
	Local _cCh,_cStr
	Local _aResult := {}
	Local _aAreaBuf := GetArea()

	_nB := 1

	Do While _nB <= len(_cVal)
		_cStr := ""
		_cCh := Substr(_cVal,_nb,1)
		Do While _cCh <> "," .and. _cch<>chr(13) .and. _nb<=len(_cVal)
			_cStr += _cCh
			_nb++
			_cCh := Substr(_cVal,_nb,1)
		Enddo
		aAdd(_aResult,_cStr)
		If _cCh==","
			_nb++
		Else
			Exit
		EndIf
	Enddo

	cTpID    := '1'
	cNumcart := " "
	cCodAut  := " "

	If Substr(_cBuf1,45,1) == "1" // cabecalho - dados do banco
		cBanco   := alltrim(_aResult[2])
		cAgencia := alltrim(_aResult[3])
		cConta   := alltrim(_aResult[4])
		cTpPag   := _aResult[13]

	ElseIf Substr(_cBuf1,45,1) == "3" // valor creditado no resumo
		cId := "14"
		dDataPg  := stod(_aResult[1])
		cResumo  := alltrim(str(val(_aResult[2])))

	ElseIf Substr(_cBuf1,45,1) == "4" // titulos creditados no resumo
		cId := "14"
		dDataven := STOD(_aResult[1])
		nValliq  := val(_aResult[6])/100
		nValbrut := val(_aResult[5])/100
		nValtx1  := 0
		cDescric := "LIQUIDACAO AMEX"
		nValtx   := 0
		cTotParc := STRZERO( IIF( val(_aResult[8]) == 0,1 ,val(_aResult[8]) ),2)
		cParcela := Iif(val(_aResult[9])<>0,vParc[val(_aresult[9])]," ")
		cCartao  := Alltrim(_aResult[4])
		cCodAut  := Alltrim(Str(val(_aResult[12])))

		//[BRUNO:29/11/2010 - Pegar numero de POS(maquineta)
		cPv	  	 := Substr(_cBuf1,28,10)
		cNoPos	 := Substr(_cBuf1,28,10)

		// aluguel de POS, tarifa de extrado e ajustes
	ElseIf Substr(_cBuf1,45,1) == "5"

		If _aResult[8] $ "ADJ0280001/ADJ0010055" // aluguel de POS e Extrato

			If _aResult[8] == "ADJ0280001" // aluguel de POS
				cId := "12"
			ElseIf _aResult[8]=="ADJ0010055" // Tarifa de Extrato
				cId := "02"
			Endif
			_nB := aScan(_aPos,{|x| alltrim(x[1])==alltrim(cPV) .and. alltrim(x[9])==Alltrim(cID)})
			If _nB==0
				aAdd(_aPos,{Alltrim(cPV),(val(_aResult[5])/100)*-1,cResumo,dDataVen,dDataPG,cBanco,cAgencia,cConta,cId})
			Else
				_aPos[_nb,2] += (val(_aResult[5])/100)*-1
			Endif

		ElseIf _aresult[8] == "ADJ0060001"  // nao faz nada, apenas atualiza o SZF avisando que os titulos não serão baixados
			_cQry := "SELECT R_E_C_N_O_ NUMREG FROM "+RETSQLNAME("SZF")
			_cQry += " WHERE ZF_FILIAL = '"+ xFilial("SZF") +"' AND ZF_ADM='10' AND ZF_RESUMO='"+cResumo+"' AND ZF_STATUS='A' AND D_E_L_E_T_=' '"
			U_ORTQUERY(_cQry,"TRA","ORTA023D_TRA.sql")
			Do While !TRA->(EOF())
				// Registra no SZF os titulos como cancelados, indicando que a AMEX nao ira creditar esses valores
				SZF->(dbGoTo(TRA->NUMREG))
				//			RecLock("SZF",.f.)
				//			SZF->ZF_STATUS := "D"
				//			SZF->(MsUnlock())
				TRA->(dbSkip())
			Enddo
			TRA->(dbCloseArea())
		Else
			//		u_log_erro("Nao existe tratamento para o tipo de ajuste "+_aResult[8])
		Endif

	Endif

	RestArea(_aAreaBuf)

Return


// JOB
User Function ORTA023J(cEmpExec, cFilExec, xParJob)
	Local _lRetJob := .t.
	Local aUnid:= {}
	Local nX := 1
	aUnid:= U_ORTPJOBU(cEmpExec, cFilExec)

	For nX := 1 To Len(aUnid)

		If Select("SX2") == 0
			OpenSm0()
		Endif
		RPCSetType(3)
		RPCSetEnv(aUnid[nX][1] , aUnid[nX][2],,,"FIN",,,,,,)

		U_ORTPJOBM(xParJob)

		if cEmpAnt <> "03"
			Conout("ORTA023D - AMBIENTE:"+upper(alltrim(GetEnvServer()))+" Não processa para as demais unidades ")
			return
		endif

		Conout("ORTA023D - AMBIENTE:"+upper(alltrim(GetEnvServer()))+" PREPARANDO JOB")
		U_JobCInfo("ORTA023D.PRW", "AMBIENTE:"+upper(alltrim(GetEnvServer()))+" PREPARANDO JOB", 2)

		Do While _lretJob
			_lRetJob := .f.

			Conout("ORTA023D - AMBIENTE:"+upper(alltrim(GetEnvServer()))+" INICIO EXECUCAO JOB")

			// abertura de ambiente
			U_JobCInfo("ORTA023D.PRW", "INICIO", 2)
			U_EEVX()
			U_ORTP109()
			U_ORTA023D()
			u_CIELOPAX() // Criacao PA7 e PA4 para a Cielo. (Peder Munksgaard em 11/08/2025)
			U_JobCInfo("ORTA023D.PRW", "FIM", 2)

			FErase("ORTA023.TMP")

			If File("ORTA023S.TMP")
				FErase("ORTA023S.TMP")
				_lretJob := .t.
			Endif

		Enddo

		//u_log_erro("Execucao Finalizada ORTA023 OK!")
		U_ORTPJOBC()

		If GetNewPar("MV_XBXTITS",.f.)
			StartJob("U_ORTA037JOB",GetEnvServer(),.f.,{"03","02"})

		Endif

	NEXT nX

Return

// JOB
User Function ORTA023k(cEmpExec, cFilExec, xParJob)
	Local aUnid:= {}
	Local nX:=1
	aUnid:= U_ORTPJOBU(cEmpExec, cFilExec)

	For nX := 1 To Len(aUnid)

		If Select("SX2") == 0
			OpenSm0()
		Endif
		RPCSetType(3)
		RPCSetEnv(aUnid[nX][1] , aUnid[nX][2],,,"FIN",,,,,,)

		U_ORTPJOBM(xParJob)

		U_JobCInfo("ORTA023D.PRW", "AMBIENTE:"+upper(alltrim(GetEnvServer()))+" PREPARANDO JOB blu", 2)

		// abertura de ambiente
		U_JobCInfo("ORTA023D.PRW", "INICIO", 2)
		_ORTA023k()
		U_JobCInfo("ORTA023D.PRW", "FIM", 2)

		//u_log_erro("Execucao Finalizada ORTA023 OK!")
		U_ORTPJOBC()


	NEXT nX

Return

/************************************************************************
 * Funções.....: ORTA023s() / STONE() /                                 *
 * Finalidade..: Importar dados dos cartões administrados pela STONE	*
 * Autor.......: Vagner Almeida                                         *
 * Data........: 24/11/20                                               *
************************************************************************/
User Function ORTA023s(cEmpExec, cFilExec, xParJob)

	Local aUnid		:= {}
	Local nX		:= 1

	aUnid:= U_ORTPJOBU(cEmpExec, cFilExec)

	For nX := 1 To Len( aUnid )

		If Select("SX2") == 0
			OpenSm0()
		Endif
		RPCSetType(3)
		RPCSetEnv(aUnid[nX][1] , aUnid[nX][2],,,"FIN",,,,,,)

		U_ORTPJOBM(xParJob)

		U_JobCInfo("ORTA023D.PRW", "AMBIENTE:"+upper(alltrim(GetEnvServer()))+" PREPARANDO JOB Stone", 2)

		// abertura de ambiente
		U_JobCInfo("ORTA023D.PRW", "INICIO", 2)

		STONE()

		U_JobCInfo("ORTA023D.PRW", "FIM", 2)

		U_ORTPJOBC()

	Next nX

Return()

Static Function STONE()

	Local _aAreaPA7 	:= GetArea()
	Local cAliasQry1	:= GetNextAlias()
	Local aDados		:= {}
	Local lPrimVez		:= .T.

	cQry := " SELECT MONTANTE    			            "
	cQry += "      , TOTALTRANSACIONADO       AS TTR  	"
	cQry += "      , TOTALSPLITSPROCESSAMENTO AS TTP	"
	cQry += "      , TOTALSPLITSPROCESSADOS   AS TSP	"
	cQry += "      , TOTALSPLITSREJEITADOS    AS TSR	"
	cQry += "      , R_E_C_N_O_               AS RECNO	"
	cQry += "      , STONECODE			                "
	cQry += "      , TRDATA			                    "
	cQry += "      , CNPJ			                    "
	cQry += "   FROM SIGA.TRANSACAOSTONE                "
	cQry += "  WHERE D_E_L_E_T_ = ' '                   "
	cQry += "    AND TOTALSPLITSPROCESSADOS > 0         "

	U_ORTQUERY(cQry,cAliasQry1,"ORTA023D_STONE.sql")

	dbSelectArea(cAliasQry1)
	(cAliasQry1)->(dbGoTop())

	While !(cAliasQry1)->( Eof() )

		// incremente regua
		IncProc("Registros com valores...")

		cQry := " SELECT PA7.PA7_RESUMO "
		cQry += "   FROM PA7030 PA7"
		cQry += "  WHERE PA7.D_E_L_E_T_ = ' ' "
		cQry += "    AND PA7.PA7_ADM    = '42' "
		cQry += "    AND PA7.PA7_RESUMO  =  '" + cValToChar( (cAliasQry1)->RECNO ) + "'"

		IF SELECT("TMPPA7") > 0
			DBSELECTAREA("TMPPA7")
			DBCLOSEAREA()
		ENDIF

		U_ORTQUERY(cQry,"TMPPA7","ORTA023D_TMPPA7_B.sql")

		DbSelectArea("TMPPA7")

		TcRefresh(RetSqlName("PA7"))

		If (TMPPA7->(EOF()))

			U_TELEGRAM("(STONE) - REGISTRANDO SPLIT NA PA7")

			DbSelectArea("PA7")
			RecLock("PA7",.T.)
			PA7->PA7_FILIAL := xFilial("PA7")
			PA7->PA7_ADM   	:= "42"
			PA7->PA7_PV 	:= (cAliasQry1)->STONECODE
			PA7->PA7_POS    := (cAliasQry1)->STONECODE
			PA7->PA7_VALOR  := (cAliasQry1)->TSP
			PA7->PA7_DTVEND := STOD( (cAliasQry1)->TRDATA )
			PA7->PA7_TOTPAR := '1'
			PA7->PA7_EMPRES := cEmpAnt
			PA7->PA7_AUTORI := (cAliasQry1)->TRDATA + cValToChar( (cAliasQry1)->RECNO )
			PA7->PA7_RESUMO	:= cValToChar( (cAliasQry1)->RECNO )
			PA7->PA7_CARTAO	:= AllTrim( (cAliasQry1)->STONECODE ) + (cAliasQry1)->TRDATA
			MsUnlock()
			TcRefresh(RetSqlName("PA7")) // Andre Carralero - 01/10/2024

			If lPrimVez

				lPrimVez	:= .F.

				aDados 		:= GetAdvFVal("SA1", { "A1_COD", "A1_LOJA" }, xFilial("SA1") + (cAliasQry1)->CNPJ, 3, { "", "" })

				DbSelectArea("PA4")
				DBSETORDER(1)
				If PA4->(DbSeek(xFilial("PA4")+cEmpAnt+(cAliasQry1)->STONECODE+(cAliasQry1)->STONECODE))
					RecLock("PA4",.F.)
				Else
					RecLock("PA4",.T.)
				Endif
				PA4->PA4_FILIAL	:=	xFilial("PA4")
				PA4->PA4_ADM	:=	"42"
				PA4->PA4_PV		:=	(cAliasQry1)->STONECODE
				PA4->PA4_POS	:=	(cAliasQry1)->STONECODE
				PA4->PA4_CODCLI	:=	aDados[1]
				PA4->PA4_LOJA	:=	aDados[2]
				PA4->PA4_CODEMP	:= 	cEmpAnt
				MsUnlock()

			EndIf

		Endif

		DbSelectArea(cAliasQry1)
		(cAliasQry1)->(DbSkip())

	EndDo

	(cAliasQry1)->(DbCloseArea())

	RestArea(_aAreaPA7)

	Conout("ORTA023D - Fim - "+DTOS(DDATABASE))

Return()

/***************************************************************************
* Programa....: BANESE                                                     *
* Finalidade..: Leitura do arquivo txt dos cartões BANESE para             *
*                a alimentação da tabela de Movimento de Cartões.          *
* Data........: 18/08/10                                                   *
***************************************************************************/

Static Function BANESE()
	Local lImp := .F.
	Private _cBand := "BANESE"
	Private _aPos := {}

	//Reinicia Variáveis
	cTpPag  := ""
	cAdmin  := "17"
	_cEmpZF := "  "
	_cFilZF := "  "
	vVettxt := {}
	cResumo  := ""
	cCartao  := ""
	cCodAut  := ""
	cParcela := "  "
	cTotParc := "  "
	cId      := ""
	cBanco   := ""
	cAgencia := ""
	cConta   := ""
	cTipo    := "CC"
	cPv      := ""
	cDescric := ""
	dDatapg  := ""
	dDataven := ""
	nValliq  := 0
	nValbrut := 0
	nVlparc  := 0
	nValtx   := 0
	nTotParc := 0
	nVlparc  := 0
	nValParc := 0
	nTotComp := 0
	nValDesc := 0
	nValDes  := 0
	nTotDesc := 0
	nLeErro  := 0

	cAdmOri	 := ""
	cNoPOS   := ""

	FT_FGOTOP()

	While !FT_FEOF()
		//Peder Munksgaard - 11/07/2018
		//Correção do problema de codepage que ocorria devido a
		//palavra comissão.
		cBuffer := AllTrim(FT_FREADLN())      // este arquivo vem em ANSI
		//cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		//
		If Substr(cBuffer,01,01) == "0"  // cabecalho

			cPv     := ""
			nLeErro	:=0
			_cEmpZF := ""
			_cFilZF := ""

			// PEGA DADOS DO CABECALHO GERAL DA LOJA
		ElseIf Substr(cBuffer,01,01) == "1"
			cPv     :=substr(cBuffer,002,015)
			cBanco  :=substr(cBuffer,074,003)
			cAgencia:=substr(cBuffer,077,006)
			cConta  :=substr(cBuffer,083,011)
			IF Substr(cBuffer,144,02) == "PF"
				//TEsta se o regsitro do cabeçalho é do tipo pgto futuro. caso contrário não importará as demais informaçãoes.
				lImp := .T.
			Else
				lImp := .F.
			Endif
			//PEGA DADOS DO PAGAMENTO
		ElseIf Substr(cBuffer,01,01) $ "2" .And. lImp
			cPv     :=substr(cBuffer,002,015)
			cId     :="02"
			cResumo :=substr(cBuffer,017,009)
			cCartao :=substr(cBuffer,052,019)
			cCodAut :=ALLTRIM(STR(VAL(substr(cBuffer,026,012))))
			cParcela:=substr(cBuffer,109,002)
			cTotParc:=substr(cBuffer,107,002)
			dDataVen:=STOD(substr(cBuffer,042,004)+substr(cBuffer,040,002)+substr(cBuffer,038,002))//ctod(substr(cBuffer,038,008))
			dDataPg :=STOD(substr(cBuffer,127,004)+substr(cBuffer,125,002)+substr(cBuffer,123,002))//ctod(substr(cBuffer,123,008))
			nValtx  :=val(substr(cBuffer,095,012))/100
			nValBrut:=val(substr(cBuffer,071,012))/100
			nVlparc :=val(substr(cBuffer,111,012))/100
			nVlparc := nValbrut
			nValLiq := nValBrut-nValTx
			cDescric:="BANESE"
			cTipo   :="42"
			GeraSZF("B")

			// PARCELAS (3) nao somam: o total do comprovante ja e o bruto do registro 2
		ElseIf Substr(cBuffer,01,01) == "3" .And. lImp
			// nao faz nada
		ElseIf Substr(cBuffer,01,01) == "4" .And. lImp
			cPv     :=substr(cBuffer,002,015)
			cId     :="07"
			cResumo :=substr(cBuffer,017,009)
			cCartao :=substr(cBuffer,085,019)
			cCodAut :=ALLTRIM(STR(VAL(substr(cBuffer,113,012))))
			cParcela:="  "
			cTotParc:="  "
			dDataVen:=STOD(substr(cBuffer,129,004)+substr(cBuffer,127,002)+substr(cBuffer,125,002))
			dDataPg :=STOD(substr(cBuffer,038,004)+substr(cBuffer,036,002)+substr(cBuffer,034,002))
			nValLiq :=val(substr(cBuffer,063,012))/100
			if substr(cBuffer,062,001)=="-"
				nValLiq*=-1
			endif
			nValtx  :=0
			nValBrut:=nValLiq
			cDescric:="BANESE"
			cTipo   :="07"
			GeraSZF("A")
			nLeErro := 0
		ElseIf Substr(cBuffer,01,01) $ '5|9'
			// nao faz nada

		Else

			nLeErro++

		EndIf

		If nLeErro > 10
			//		u_log_erro("Erro ao ler o aquivo >> " + Alltrim(cFile))
			nErros++
			//		exit
			//		Comentado por Marcos Furtado - 11/12/13. Não se pode garantir que não vira linhas válidas após 10 linhas desconsideradas.
		Endif
		//	dbskip()
		FT_FSKIP()

	EndDo

	// Gera Titulo de Aluguel de POS, caso exista
	If len(_aPos)>0
		gerapos(_apos)
	Endif

	//DbSelectArea("AMEX")
	//DbCloseArea()
	FT_FUSE()

Return()


/***************************************************************************
* Programa....: credishop                                                  *
* Finalidade..: Leitura do arquivo txt dos cartoes credishop para          *
*                a alimentação da tabela de Movimento de Cartoes.          *
* Data........: 21.11.12 - Decio                                           *
***************************************************************************/

Static Function CredLay341(cLinha)
Return Substr(cLinha,01,01) == "0" .and. Val(Substr(cLinha,17,08)) > 20000000 .and. Val(Substr(cLinha,31,08)) > 20000000

Static Function Credishop()
	Private _cBand := "CREDISHOP"
	Private _aPos := {}

	//Reinicia Variáveis
	cTpPag  := ""
	cAdmin  := "22"
	_cEmpZF := "  "
	_cFilZF := "  "
	vVettxt := {}
	cResumo  := ""
	cCartao  := ""
	cCodAut  := ""
	cParcela := "  "
	cTotParc := "  "
	cId      := ""
	cBanco   := ""
	cAgencia := ""
	cConta   := ""
	cTipo    := "CC"
	cPv      := ""
	cDescric := ""
	dDatapg  := ""
	dDataven := ""
	nValliq  := 0
	nValbrut := 0
	nValtx   := 0
	nTotParc := 0
	nVlparc  := 0
	nValParc := 0
	nTotComp := 0
	nValDesc := 0
	nValDes  := 0
	nTotDesc := 0
	nLeErro  := 0
	nTotLin  := 0
	cLayout  := ""

	cAdmOri	 := ""
	cNoPOS   := ""

	FT_FGOTOP()

	While !FT_FEOF()
		//Peder Munksgaard - 11/07/2018
		//Correção do problema de codepage que ocorria devido a
		//palavra comissão.
		//cBuffer := AllTrim(FT_FREADLN())
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		If !Empty(cBuffer)
			nTotLin++
		EndIf
		//
		If Substr(cBuffer,01,01) == "0"  // cabecalho geral
			cPv     := ""
			nLeErro :=0
			_cEmpZF := ""
			_cFilZF := ""
			cLayout := IIf(Substr(cBuffer,43,15) == "CREDISHOP200.01", "200.01", "3.4.1")
			Conout("ORTA023D - Credishop layout "+cLayout+" - "+cFile)

			// pega dados do cabecalho do lote, filtrando somente as vendas
			//[Peder - 17/09/2026] Aceita tambem o tipo "PAG" (extrato de pagamento
			//efetuado). O layout do registro tipo "1" e identico ao do tipo "PRE"
			//(previsao de pagamento): mesmas posicoes de PV, parcela e dados
			//bancarios (pos. 171 a 193).
		ElseIf Substr(cBuffer,01,01) == "1" .and. Substr(cBuffer,IIf(cLayout == "200.01",28,31),03) $ "PRE|PAG"
			If cLayout == "200.01"
				cPv      :=substr(cBuffer,002,010)
				cParcela :=substr(cBuffer,023,002)
				cTotParc :=substr(cBuffer,026,002)
				cBanco   :=substr(cBuffer,171,004)
				cAgencia :=substr(cBuffer,175,005)
				cConta   :=substr(cBuffer,180,014)
			Else
				cPv      :=substr(cBuffer,002,015)
				cParcela :=substr(cBuffer,026,002)
				cTotParc :=substr(cBuffer,029,002)
				cBanco   :=substr(cBuffer,146,004)
				cAgencia :=substr(cBuffer,150,005)
				cConta   :=substr(cBuffer,155,011)
			EndIf
			cNoPOS  :=cPv

			// pega dados somente das vendas
			//[Peder - 17/09/2026] O filtro original exigia resumo iniciado em
			//"100", o que rejeitava todas as vendas dos arquivos "PAG", cujos
			//resumos sao numerados na faixa 2xxxxxxx. O primeiro digito do
			//resumo (pos. 12) identifica a faixa: aceita "1" (PRE) e "2" (PAG).
		ElseIf Substr(cBuffer,01,01) == "2" .and. IIf(cLayout == "200.01", Substr(cBuffer,12,01) $ "12", Substr(cBuffer,31,03) $ "PRE|PAG")
			If cLayout == "200.01"
				cPv     :=substr(cBuffer,002,010)
				cResumo :=substr(cBuffer,012,008)
				cCartao :=substr(cBuffer,023,019)
				cCodAut :=ALLTRIM(STR(VAL(substr(cBuffer,108,006))))
				nValBrut:=val(substr(cBuffer,051,013))/100
			Else
				cPv     :=substr(cBuffer,002,015)
				cResumo :=substr(cBuffer,126,006)
				cCartao :=substr(cBuffer,050,019)
				cCodAut :=ALLTRIM(STR(VAL(substr(cBuffer,120,006))))
				nValBrut:=val(substr(cBuffer,070,013))/100
			EndIf
			cNoPOS  :=cPv
			cId     :="02"
			cResumo :=substr(cBuffer,012,008)
			cCartao :=substr(cBuffer,023,019)
			cCodAut :=ALLTRIM(substr(cBuffer,108,006))
			dDataVen:=Stod(substr(cBuffer,042,008))
			nValBrut:=val(substr(cBuffer,051,013))/100
			cDescric:="CREDISHOP"
			cTipo   :="CC"
			GeraSZF("B")
			//[Peder - 17/09/2026] Trailer do arquivo (tipo "9" - totalizador) e
			//linhas em branco sao ignorados: nao geram registro e nao contam
			//como erro de leitura.
		ElseIf Substr(cBuffer,01,01) == "9"
			If cLayout == "200.01"
				nTotEsp := nTotLin - 2
			Else
				nTotEsp := nTotLin
			EndIf
			If Val(Substr(cBuffer,02,11)) != nTotEsp
				Conout("ORTA023D - Credishop rodape divergente ("+cLayout+") - rodape "+AllTrim(Str(Val(Substr(cBuffer,02,11))))+" lidos "+AllTrim(Str(nTotEsp))+" - "+cFile)
			EndIf
		ElseIf Empty(cBuffer)
			// sem tratamento
		ElseIf cLayout == "3.4.1" .and. Substr(cBuffer,01,01) $ "123"
			// antecipacoes, ajustes e pagamentos da 3.4.1 fora do escopo de vendas
		Else
			nLeErro++
		EndIf

		If nLeErro > 10
			//		u_log_erro("Erro ao ler o aquivo >> " + Alltrim(cFile))
			nErros++
			//		exit
			//		Comentado por Marcos Furtado - 11/12/13. Não se pode garantir que não vira linhas válidas após 10 linhas desconsideradas.
		Endif
		//	dbskip()
		FT_FSKIP()

	EndDo

	// Gera Titulo de Aluguel de POS, caso exista
	If len(_aPos)>0
		gerapos(_apos)
	Endif

	//DbSelectArea("AMEX")
	//DbCloseArea()
	FT_FUSE()

Return()



/***************************************************************************
* Programa....: Cielo                                                      *
* Finalidade..: Leitura do arquivo txt dos cartoes cielo                   *
*                a alimentação da tabela de Movimento de Cartoes.          *
* Data........: 12.03.13                                                   *
***************************************************************************/

Static Function Cielo()
	Private _cBand := "" //CIELO"
	Private _aPos := {}

	//alert("cielo")
	//alert("teste")

	//Reinicia Variáveis
	cTpPag  := ""
	cAdmin  := "26"
	_cEmpZF := "  "
	_cFilZF := "  "
	vVettxt := {}
	cResumo  := ""
	cCartao  := ""
	cCodAut  := ""
	cParcela := "  "
	cTotParc := "  "
	cId      := ""
	cBanco   := ""
	cAgencia := ""
	cConta   := ""
	cTipo    := "CC"
	cPv      := ""
	cDescric := ""
	dDatapg  := ""
	dDataven := ""
	nValliq  := 0
	nValbrut := 0
	nValtx   := 0
	nTotParc := 0
	nVlparc  := 0
	nValParc := 0
	nTotComp := 0
	nValDesc := 0
	nValDes  := 0
	nTotDesc := 0
	nLeErro  := 0

	cAdmOri	 := ""
	cNoPOS   := ""

	FT_FGOTOP()
	cJaLido:=""  && Henrique - SSI 31895
	While !FT_FEOF()
		//Peder Munksgaard - 11/07/2018
		//Correção do problema de codepage que ocorria devido a
		//palavra comissão.
		//cBuffer := AllTrim(FT_FREADLN())
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		//
		//	alert(cBuffer)

		If Substr(cBuffer,01,01) == "0"  // cabecalho geral
			cPv     := ""

			nLeErro :=0
			_cEmpZF := ""
			_cFilZF := ""

			// pega dados do cabecalho do lote, filtrando somente as vendas
		ElseIf Substr(cBuffer,01,01) == "1" //.and. Substr(cBuffer,27,03) == "PRE"

			*********** Administradora Visa / Debito e Credito **************************************

			if substr(cBuffer,185,003) = "001" .and. substr(cBuffer,12,001) = "5"             && Henrique - 15/10/2013 - SSI 31879
				&&        if substr(cBuffer,185,003) = "001" .and. substr(cBuffer,131,002) $ "41|44"      && Henrique - 15/10/2013 - SSI 31879
				cAdmin  := "26" //"18" //"26"
				cAdmOri := "18" //"26" //"18"
				cDescric:= "VISA/DEBITO"
				cTipo   := "CD"
			endif

			if substr(cBuffer,185,003) = "001" .and. substr(cBuffer,12,001) <> "5"            && Henrique - 15/10/2013 - SSI 31879
				&&        if substr(cBuffer,185,003) = "001" .and. substr(cBuffer,131,002) = "43"         && Henrique - 15/10/2013 - SSI 31879
				cAdmin  := "26"//"11" //"26"
				cAdmOri := "11"//"26" //"11"
				cDescric:= "VISA/CREDITO"
				cTipo   := "CC"
			endif

			***********************************************************************************

			*********** Mastercard / Debito e Credito ********************************************

			if substr(cBuffer,185,003) = "002" .and. substr(cBuffer,12,001) = "5"             && Henrique - 15/10/2013 - SSI 31879
				&&        if substr(cBuffer,185,003) = "002" .and. substr(cBuffer,131,002) = "11"         && Henrique - 15/10/2013 - SSI 31879
				cAdmin  := "26" //"19" //"26"
				cAdmOri := "12" //"26" //"12"
				cDescric:= "MASTER/DEBITO"
				cTipo   := "CD"
			endif

			if substr(cBuffer,185,003) = "002" .and. substr(cBuffer,12,001) <> "5"            && Henrique - 15/10/2013 - SSI 31879
				&&        if substr(cBuffer,185,003) = "002" .and. substr(cBuffer,131,002) $ "10|12"      && Henrique - 15/10/2013 - SSI 31879
				cAdmin  := "26" //"12" //"26"
				cAdmOri := "19" //"26" //"19"
				cDescric:= "MASTER/CREDITO"
				cTipo   := "CC"
			endif

			***********************************************************************************

			*********** ELO / Debito e Credito ***************************************************

			if substr(cBuffer,185,003) = "007" .and. substr(cBuffer,12,001) = "5"
				cAdmin  := "26" //"25" //"26"
				cAdmOri := "25" //"26" //"25"
				cDescric:= "ELO/DEBITO"
				cTipo   := "CD"

			endif

			if substr(cBuffer,185,003) = "007" .and. substr(cBuffer,12,001) <> "5"
				cAdmin  := "26" //"25" //"26"
				cAdmOri := "25" //"26" //"25"
				cDescric:= "ELO/CREDITO"
				cTipo   := "CC"

			endif

			***********************************************************************************

			*********** DINERS (E MESMO DO AMEX) / Debito e Credito *******************************

			if substr(cBuffer,185,003) = "009" .and. substr(cBuffer,12,001) = "5"
				cAdmin  := "26" //"10" //"26"
				cAdmOri := "10" //"26" //"10"
				cDescric:= "DINERS/DEBITO"
				cTipo   := "CD"

			endif

			if substr(cBuffer,185,003) = "009" .and. substr(cBuffer,12,001) <> "5"
				cAdmin  := "26" // "10" //"26"
				cAdmOri := "10" // "26" //"10"
				cDescric:= "DINERS/CREDITO"
				cTipo   := "CC"

			endif

			***********************************************************************************

			***       	aAdd(aRegPA7,{cAdmin,;	    	//1 Adm Captura
				***				  cCodAut,;     //2  Codigo de Autorização
				***				  AllTrim(cCartao),;    //3  Numero de Cartao
				***				  cPv,;		   //4  Ponto de Venda
				***				  cArquivo,;	   //5	Arquivo de Importaçãp
				***				  dDataven,;	   //6  Data da Venda
				***				  cTotParc,;	   //7  Parcelas
				***				  nValbrut,;   //8	Valor Total de Parcelas
				***				  cAdmOri,;           //9   Adm Origem
				***				  cNoPos,;			  //10  No POS(Maquineta)
				***				  cDescric,;		  //11  Descricao da Operacao da Administradora
				***				  cResumo})	  //12 Resumo

			cPv     := substr(cBuffer,002,010)
			***     cParcela:=substr(cBuffer,022,002)
			***		cTotParc:=substr(cBuffer,025,002)


			cBanco  :=substr(cBuffer,100,004)
			cAgencia:=substr(cBuffer,104,005)
			cConta  :=substr(cBuffer,109,014)
			cNoPos  :=substr(cBuffer,225,008)

			// pega dados somente das vendas

		ElseIf Substr(cBuffer,01,01) $ "2" //.and. Substr(cBuffer,12,03) $ "100"
			cPv      :=substr(cBuffer,002,010)
			cId      :="02"
			cResumo  := substr(cBuffer,012,007)
			cCartao  := AllTrim(substr(cBuffer,019,019))
			cCodAut  := SubStr(cBuffer,093,006) + substr(cBuffer,067,006) && Henrique - 06/11/2013 - SSI 31890 Posicao 093,006=DOC  067,006=Autorização
			cNoPos   := substr(cBuffer,153,008)

			//		dDataVen :=stod(substr(cBuffer,038,008))

			ddd2     := substr(cBuffer,038,008)
			ddd3     := substr(ddd2,7,2)+"/"+substr(ddd2,5,2)+"/"+substr(ddd2,1,4)
			dDataVen := ctod(ddd3)

			//		alert(dDataVen)
			//		ALERT(substr(cBuffer,038,008))

			cParcela:=substr(cBuffer,060,002)
			cTotParc:=substr(cBuffer,062,002)
			If cTipo = "CD"
				nValBrut:=val(substr(cBuffer,47 ,013))/100 //		nValBrut:=val(substr(cBuffer,047,013))/100
			Else
				nValBrut:=val(substr(cBuffer,114,013))/100 //		nValBrut:=val(substr(cBuffer,047,013))/100
				If nValBrut == 0 .AND. val(substr(cBuffer,47 ,013))/100 # 0
					nValBrut:=val(substr(cBuffer,47 ,013))/100
				EndIf
			EndIf

			If Val(cTotParc) == 0
				cTotParc:="01"
			EndIf
			If Val(cParcela) == 0
				cParcela:="01"
			EndIf

			***		cDescric:="CREDISHOP"
			***     cTipo   :="CC"

			GeraSZF("B")


			&& Henrique - SSI 31895 (Cancelamento)
			If cJaLido # SubStr(cBuffer,093,06) + SubStr(cBuffer,067,06)
				cJaLido    :=SubStr(cBuffer,093,06) + SubStr(cBuffer,067,06)
				cPA7_AUTORI:=SubStr(cBuffer,093,06) + SubStr(cBuffer,067,06)
				cPA7_PV    :=SubStr(cBuffer,073,10)
				cPA7_POS   :=SubStr(cBuffer,153,08)
				cDtCanc    :=SubStr(cBuffer,038,08)
				dPA7_DTCANC:=CToD(Left(cDtCanc,2) + "/" + Substr(cDtCanc,3,2) + "/" + Right(cDtCanc,4))
				nPA7_VLCANC:=Val(SubStr(cBuffer,047,13))/100
				nRegPA7    :=PA7->(RecNo())
				//nOrdPA7    :=PA7->(DbSetOrder(02))
				PA7->(DbSetOrder(02))
				If PA7->(DbSeek(xFilial("PA7") + cPA7_AUTORI))
					If AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. (AllTrim(PA7->PA7_PV) # AllTrim(cPA7_PV) .OR. AllTrim(PA7->PA7_POS) # AllTrim(cPA7_POS))
						While AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. (AllTrim(PA7->PA7_PV) # AllTrim(cPA7_PV) .OR. AllTrim(PA7->PA7_POS) # AllTrim(cPA7_POS)) .AND. ! PA7->(Eof())
							PA7->(DbSkip())
						End
					EndIf

					If AllTrim(PA7->PA7_AUTORI) == cPA7_AUTORI .AND. AllTrim(PA7->PA7_PV) == AllTrim(cPA7_PV) .AND. AllTrim(PA7->PA7_POS) == AllTrim(cPA7_POS)
						If PA7->(RecLock("PA7",.F.))
							if !empty(dPA7_DTCANC)
								PA7->PA7_DTCANC:=dPA7_DTCANC
								PA7->PA7_VLCANC+=nPA7_VLCANC
								//
							endif
							PA7->(MsUnlock())
						EndIf
					EndIf
				EndIf
				PA7->(DbSetOrder(02))
				PA7->(DbGoTo(nRegPA7))
			EndIf

		Else
			nLeErro++
		EndIf

		If nLeErro > 10
			//		u_log_erro("Erro ao ler o aquivo >> " + Alltrim(cFile))
			nErros++
			//		exit
			//		Comentado por Marcos Furtado - 11/12/13. Não se pode garantir que não vira linhas válidas após 10 linhas desconsideradas.
		Endif
		//	dbskip()
		FT_FSKIP()

	EndDo

	// Gera Titulo de Aluguel de POS, caso exista

	if cempant<>"02"

		If len(_aPos)>0
			gerapos(_apos)
		Endif

	endif

	//DbSelectArea("AMEX")
	//DbCloseArea()
	FT_FUSE()

Return()



*********************************************************************************************



/*
ÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜÜ
±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±
±±ÉÍÍÍÍÍÍÍÍÍÍÑÍÍÍÍÍÍÍÍÍÍËÍÍÍÍÍÍÍÑÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍËÍÍÍÍÍÍÑÍÍÍÍÍÍÍÍÍÍÍÍÍ»±±
±±ºFuncao	 ³GeraPA7   ºAutor  ³Bruno				 º Data ³  24/11/10   º±±
±±ÌÍÍÍÍÍÍÍÍÍÍØÍÍÍÍÍÍÍÍÍÍÊÍÍÍÍÍÍÍÏÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÊÍÍÍÍÍÍÏÍÍÍÍÍÍÍÍÍÍÍÍÍ¹±±
±±ºDesc.     ³ Função para incluir registros na nova tabela de cartao on  º±±
±±º          ³ line.							                          º±±
±±ÌÍÍÍÍÍÍÍÍÍÍØÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍ¹±±
±±ºUso       ³ AP8-Ortobom                                                º±±
±±ÈÍÍÍÍÍÍÍÍÍÍÏÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍÍ¼±±
±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±±
ßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßßß
*/

***************************************************************************
Static Function fGeraPA7()
	***************************************************************************

	Local aArea := GetArea()
	Local cQry  := ""
	Local i:= 0

	for i:=1 to len(aRegPA7)
		cQry := " SELECT R_E_C_N_O_ "
		cQry += "   FROM V_PA7UNI "
		cQry += "  WHERE D_E_L_E_T_ = ' ' "
		cQry += "    AND PA7_FILIAL = '"+ xFilial("PA7") +"' "
		cQry += "    AND PA7_ADM = '"+aRegPA7[I,1]+"' "
		cQry += "    AND PA7_AUTORI = '"+aRegPA7[I,2]+"' "
		cQry += "    AND PA7_CARTAO = '"+AllTrim(aRegPA7[I,3])+"' "
		cQry += "    AND PA7_DTVEND = '"+dtos(aRegPA7[I,6])+"' "

		IF SELECT("TMPPA7") > 0
			DBSELECTAREA("TMPPA7")
			DBCLOSEAREA()
		ENDIF

		U_ORTQUERY(cQry,"TMPPA7","ORTA023D_TMPPA7_C.sql")

		DbSelectArea("TMPPA7")

		TcRefresh(RetSqlName("PA7"))

		if TMPPA7->(EOF())
			RecLock("PA7", .T.)
			PA7->PA7_FILIAL := XFILIAL("PA7")
			PA7->PA7_ADM    := aRegPA7[I,1]
			PA7->PA7_AUTORI := aRegPA7[I,2]
			PA7->PA7_CARTAO := AllTrim(aRegPA7[I,3])
			PA7->PA7_PV	    := aRegPA7[I,4]
			PA7->PA7_NOMARQ := aRegPA7[I,5]
			PA7->PA7_DTVEND := aRegPA7[I,6]
			PA7->PA7_TOTPAR := aRegPA7[I,7]
			PA7->PA7_VALOR  := aRegPA7[I,8]
			PA7->PA7_ADMORI := aRegPA7[I,9]
			PA7->PA7_POS	:= aRegPA7[I,10]
			PA7->PA7_DESCRI := aRegPA7[I,11]
			PA7->PA7_RESUMO := aRegPA7[I,12]
			MSUNLOCK()
			TcRefresh(RetSqlName("PA7")) // Andre Carralero - 01/10/2024
		endif

		dbCloseArea()
	next

	RestArea(aArea)

Return()

****************************
Static Function fVerGrv(cArq,cAdm)
	****************************
	Local cQry:= ""
	Local lRet:= .T.

	cQry += " SELECT COUNT(*) QTDGRV "
	//cQry += "  FROM "+RETSQLNAME("PA7")+" PA7 "
	cQry += "  FROM V_PA7UNI PA7 "
	cQry += " WHERE D_E_L_E_T_ = ' ' "
	cQry += "   AND PA7_FILIAL = '"+xFilial("PA7")+"' "
	cQry += "   AND PA7_NOMARQ = '"+cArq+"'"
	cQry += "   AND PA7_ADM = '"+cAdm+"' "

	U_ORTQUERY(cQry,"TGRV","ORTA023D_TGRV.sql")

	DbSelectArea("TGRV")

	if TGRV->QTDGRV < len(aRegPA7)
		//	lRet:= .F.
		//Comentado em 11/12/2013 por Marcos Furtado para mover o arquivo lido idependente da qtd de registros do arquivo
		//importado para PA7
	endif
	DbSelectArea("TGRV")
	dbClosearea()


return lRet




/***************************************************************************
* Programa....: BANESE                                                     *
* Finalidade..: Leitura do arquivo txt dos cartões BANESE para             *
*                a alimentação da tabela de Movimento de Cartões.          *
* Data........: 18/08/10                                                   *
***************************************************************************/

Static Function BANESCARD()
	Private _cBand := "BANESCARD"
	Private _aPos := {}

	//Reinicia Variáveis
	cTpPag  := ""
	cAdmin  := "33"
	cAdmOri := "33"
	_cEmpZF := "  "
	_cFilZF := "  "
	vVettxt := {}
	cResumo  := ""
	cCartao  := ""
	cCodAut  := ""
	cParcela := "  "
	cTotParc := "  "
	cId      := ""
	cBanco   := ""
	cAgencia := ""
	cConta   := ""
	cTipo    := "CC"
	cPv      := ""
	cDescric := ""
	dDatapg  := ""
	dDataven := ""
	nValliq  := 0
	nValbrut := 0
	nVlparc  := 0
	nValtx   := 0
	nTotParc := 0
	nVlparc  := 0
	nValParc := 0
	nTotComp := 0
	nValDesc := 0
	nValDes  := 0
	nTotDesc := 0
	nLeErro  := 0
	cNoPOS   := ""



	FT_FGOTOP()

	While !FT_FEOF()
		cBuffer:=FT_FREADLN()
		If Substr(cBuffer,01,01) == "0"  // cabecalho
			cPv     := ""
			nLeErro:=0
			_cEmpZF := ""
			_cFilZF := ""

			// PEGA DADOS DO CABECALHO GERAL DA LOJA
		ElseIf Substr(cBuffer,01,01) == "1"
			cPv     :=substr(cBuffer,007,010)
			cNoPOS  :=substr(cBuffer,007,010) //Thais
			cBanco  :=substr(cBuffer,106,003)
			cAgencia:=substr(cBuffer,109,005)
			cConta  :=substr(cBuffer,114,014)
			cNoPos  :=substr(cBuffer,007,010)
			If Substr(cBuffer,140,001) $ "D"
				cTipo	:= "CD"
			Else
				cTipo	:= "CC"
			Endif
			//PEGA DADOS DO PAGAMENTO
		ElseIf Substr(cBuffer,01,01) $ "2"

			cId     :="02"
			//dDataVen:=ctod(substr(cBuffer,017,008))
			dDataVen:=Stod(substr(cBuffer,017,008))
			cResumo :=substr(cBuffer,026,009)
			cCartao :=AllTrim(substr(cBuffer,038,016))
			nValBrut:=val(substr(cBuffer,056,017))/100
			nValLiq :=val(substr(cBuffer,073,017))/100
			nValtx  :=val(substr(cBuffer,090,017))/100
			cCodAut :=ALLTRIM(STR(VAL(substr(cBuffer,151,010))))
			cAdmin  := "33"
			If cTipo	== "CD"
				cAdmin  := "31"
				cDescric:="BANESCARD DEBITO"
				cTotParc:="01"
			ELSEIF substr(cBuffer,107,002) == "00"
				cDescric:="BANESCARD ROTATIVO"
				cTotParc:="01"
			ELSE
				cDescric:="BANESCARD PARCELADO"
				cTotParc:=substr(cBuffer,107,002)
			ENDIF

			GeraSZF("B")
		Else

			nLeErro++

		EndIf

		If nLeErro > 10
			//		u_log_erro("Erro ao ler o aquivo >> " + Alltrim(cFile))
			nErros++
			//		exit
			//		Comentado por Marcos Furtado - 11/12/13. Não se pode garantir que não vira linhas válidas após 10 linhas desconsideradas.
		Endif
		FT_FSKIP()

	EndDo

	// Gera Titulo de Aluguel de POS, caso exista
	If len(_aPos)>0
		gerapos(_apos)
	Endif

	FT_FUSE()

Return()

/*----------INÍCIO SSI 12359----------*/
/***************************************************************************
* Programa....: BANRISUL                                                   *
* Finalidade..: Leitura do arquivo txt dos cartões BANRISUL para           *
*                a alimentação da tabela de Movimento de Cartões.          *
* Data........: 26/08/15                                                   *
***************************************************************************/

Static Function Banrisul()
	Private _cBand := "" //BANRISUL
	Private _aPos := {}

	//Reinicia Variáveis
	cTpPag  := ""
	cAdmin  := "15"
	_cEmpZF := "  "
	_cFilZF := "  "
	vVettxt := {}
	cResumo  := ""
	cCartao  := ""
	cCodAut  := ""
	cParcela := "  "
	cTotParc := "  "
	cId      := ""
	cBanco   := ""
	cAgencia := ""
	cConta   := ""
	cTipo    := "CC"
	cPv      := ""
	cDescric := ""
	dDatapg  := ""
	dDataven := ""
	nValliq  := 0
	nValbrut := 0
	nValtx   := 0
	nTotParc := 0
	nVlparc  := 0
	nValParc := 0
	nTotComp := 0
	nValDesc := 0
	nValDes  := 0
	nTotDesc := 0
	nLeErro  := 0
	_aBanri	 := {} //SSI 15976

	cAdmOri	 := ""
	cNoPOS   := ""

	FT_FGOTOP()
	cJaLido:=""
	While !FT_FEOF()
		//Peder Munksgaard - 11/07/2018
		//Correção do problema de codepage que ocorria devido a
		//palavra comissão.
		//cBuffer := AllTrim(FT_FREADLN())
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		//

		If Substr(cBuffer,01,02) == "00"

			cPv     := ""

			nLeErro :=0
			_cEmpZF := ""
			_cFilZF := ""

		ElseIf Substr(cBuffer,01,02) == "10" .AND. (substr(cBuffer,095,004) = "0200" .OR. substr(cBuffer,095,004) = "9100")

			if substr(cBuffer,105,004) = "PGTA"
				cAdmin  := "15"
				cDescric:= "BANRICOMPRAS DEBITO"
				cTipo   := "CD"
				cTotParc := "01"
			endif

			if substr(cBuffer,105,004) = "PGTX"
				cAdmin  := "23"
				cDescric:= "BANRICOMPRAS CREDITO"
				cTipo   := "CC"
				cTotParc := Substr(cBuffer,069,002)
			endif

			if substr(cBuffer,105,004) = "PGTP"
				cAdmin  := "15"
				cDescric:= "BANRICOM PRE-DATADO"
				cTipo   := "CD"
				cTotParc := "01"
			endif

			if substr(cBuffer,105,004) = "PGCC"
				cAdmin  := "24"
				If substr(cBuffer,291,003) = "002"
					cAdmOri := "12"
				ElseIf substr(cBuffer,291,003) = "003"
					cAdmOri := "11"
				EndIf

				If substr(cBuffer,099,006) $ ('003000|003100')
					cDescric:= "VERDECARD CREDITO"
				Else
					cDescric:= "VERDECARD PARC EMIS"
				EndIf
				cTipo   := "CC"
				cTotParc := Substr(cBuffer,069,002)
			endif

			cPv      := RIGHT(substr(cBuffer,028,015),10)
			cNoPOS	 := RIGHT(substr(cBuffer,028,015),10)
			cId      := "02"
			cResumo  := substr(cBuffer,051,008)
			If cAdmin  == "24"
				cCartao  := AllTrim(substr(cBuffer,294,006)+"000000"+substr(cBuffer,300,004))
			Else
				cCartao  := AllTrim(substr(cBuffer,291,006)+"000000"+substr(cBuffer,297,004))
			EndIf
			cCodAut  := SubStr(cBuffer,059,008)

			dDataVen:= Stod(substr(cBuffer,077,008))

			If Empty(cTotParc)
				cTotParc := '01'
			EndIf

			nValbrut := Val(Substr(cBuffer,111,015))/100
			nVlparc := Val(Substr(cBuffer,126,015))/100

			//Gravação da Tabela SZF com a confirmação das Vendas Aprovadas pela Administradora.
			GeraSZF("A")

		Else
			nLeErro++
		EndIf

		If nLeErro > 10
			nErros++
		Endif

		FT_FSKIP()

	EndDo

	FT_FUSE()

Return()

/***************************************************************************
* Programa....: VERO                                                       *
* Finalidade..: Leitura dos arquivos txt VERO (Banrisul Pagamentos) para   *
*                a alimentacao da tabela de Movimento de Cartoes (PA7).    *
*                BJR02 (BJRVCA1) / BJRVCP1 : Banricompras - operacoes      *
*                BJR72 (BJRVCM8) / BJRVCM9 : Adquirencia  - operacoes      *
*                BJR06 (BJRVCC1) / BJRVCMB : previsao de credito (nao venda)*
*                BJR08 (BJRVCB1)           : cancelamentos (nao venda)     *
*                Somente situacao 00 a 04 (OK) entra como venda.           *
* Data........: 29/10/26                                                   *
***************************************************************************/

Static Function Vero()
	Local cIdArq  := ""
	Local cSitua  := ""
	Local cServ   := ""
	Local lAdq    := .F.
	Local lVenda  := .F.
	Local nIgnSit := 0
	Local nIgnSrv := 0
	Local nVendas := 0

	//Reinicia Variaveis
	cTpPag  := ""
	cAdmin  := ""
	_cEmpZF := "  "
	_cFilZF := "  "
	vVettxt := {}
	cResumo  := ""
	cCartao  := ""
	cCodAut  := ""
	cParcela := "  "
	cTotParc := "  "
	cId      := ""
	cBanco   := ""
	cAgencia := ""
	cConta   := ""
	cTipo    := "CC"
	cPv      := ""
	cDescric := ""
	dDatapg  := ""
	dDataven := ""
	nValliq  := 0
	nValbrut := 0
	nValtx   := 0
	nTotParc := 0
	nVlparc  := 0
	nValParc := 0
	nTotComp := 0
	nValDesc := 0
	nValDes  := 0
	nTotDesc := 0
	nLeErro  := 0

	cAdmOri	 := ""
	cNoPOS   := ""

	FT_FGOTOP()
	While !FT_FEOF()
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")

		If Substr(cBuffer,01,02) == "00"

			cPv     := ""
			cIdArq  := AllTrim(Upper(Substr(cBuffer,043,008)))
			lAdq    := (cIdArq == "BJRVCM8" .Or. cIdArq == "BJRVCM9")
			lVenda  := (lAdq .Or. cIdArq == "BJRVCA1" .Or. cIdArq == "BJRVCP1")
			nLeErro := 0
			_cEmpZF := ""
			_cFilZF := ""

			If !lVenda
				Conout("ORTA023D - Vero - arquivo "+cIdArq+" nao gera venda (previsao de credito/cancelamento) - "+cFile)
			EndIf

		ElseIf Substr(cBuffer,01,02) == "10" .And. lVenda .And. (Substr(cBuffer,095,004) == "0200" .Or. Substr(cBuffer,095,004) == "9100")

			// Somente OK (00-04) e venda. Pendente, nao autorizada, cancelada, estornada ficam fora.
			cSitua := Substr(cBuffer,109,002)
			If !(cSitua $ "00|01|02|03|04")
				nIgnSit++
				FT_FSKIP()
				Loop
			EndIf

			cServ   := Substr(cBuffer,105,004)
			cAdmin  := ""
			cAdmOri := ""

			If cServ == "PGTA" .Or. cServ == "PGTP"
				cAdmin   := "15"
				cDescric := IIf(cServ == "PGTA","BANRICOMPRAS DEBITO","BANRICOM PRE-DATADO")
				cTipo    := "CD"
				cTotParc := "01"
			ElseIf cServ == "PGTX"
				cAdmin   := "23"
				cDescric := "BANRICOMPRAS CREDITO"
				cTipo    := "CC"
				cTotParc := Substr(cBuffer,069,002)
			ElseIf cServ == "PGCC" .And. lAdq
				cAdmin   := "24"
				If Substr(cBuffer,291,003) == "002"
					cAdmOri := "12"
				ElseIf Substr(cBuffer,291,003) == "003"
					cAdmOri := "11"
				EndIf
				If Substr(cBuffer,099,006) $ "003000|003100"
					cDescric := "VERDECARD CREDITO"
				Else
					cDescric := "VERDECARD PARC EMIS"
				EndIf
				cTipo    := "CC"
				cTotParc := Substr(cBuffer,069,002)
			EndIf

			If Empty(cAdmin)
				// servico sem administradora cadastrada (PGCD/PGAL/PGRE/PGVE/PGAU/PGTF/PGTB/PGTJ): nao grava
				nIgnSrv++
				Conout("ORTA023D - Vero - servico "+cServ+" sem administradora mapeada, registro ignorado - "+cFile)
				FT_FSKIP()
				Loop
			EndIf

			cPv      := RIGHT(Substr(cBuffer,028,015),10)
			cNoPOS   := RIGHT(Substr(cBuffer,028,015),10)
			cId      := "02"
			cResumo  := Substr(cBuffer,051,008)
			If lAdq
				cCartao  := AllTrim(Substr(cBuffer,294,006)+"000000"+Substr(cBuffer,300,004))
			Else
				cCartao  := AllTrim(Substr(cBuffer,291,006)+"000000"+Substr(cBuffer,297,004))
			EndIf
			cCodAut  := Substr(cBuffer,059,008)

			dDataVen := Stod(Substr(cBuffer,077,008))

			If Empty(cTotParc)
				cTotParc := "01"
			EndIf

			nValbrut := Val(Substr(cBuffer,111,015))/100
			nVlparc  := Val(Substr(cBuffer,126,015))/100

			//Gravacao da Tabela PA7 (via aRegPA7) com a confirmacao das Vendas Aprovadas pela Administradora.
			GeraSZF("A")
			nVendas++

		ElseIf Substr(cBuffer,01,02) == "99" .Or. Substr(cBuffer,01,02) == "20" .Or. (Substr(cBuffer,01,02) == "10" .And. !lVenda)
			// trailer, parcelas de previsao de credito e movimentos de arquivos que nao sao venda: nada a fazer
		Else
			nLeErro++
		EndIf

		If nLeErro > 10
			nErros++
		Endif

		FT_FSKIP()

	EndDo

	Conout("ORTA023D - Vero - "+cFile+" - id "+cIdArq+" - vendas: "+AllTrim(Str(nVendas))+" - fora de venda (situacao): "+AllTrim(Str(nIgnSit))+" - servico nao mapeado: "+AllTrim(Str(nIgnSrv)))

	FT_FUSE()

Return()

/*----------FIM SSI 12359----------*/
****************************
User Function Orta023()
	****************************
	Prepare Environment Empresa "03" Filial "02"
	U_ORTA023d()
Return()


//-------------------------------------------------
Static Function ValidaArquivo(cFile)
	Local nHandle
	Local cBuffer := ""
	Local cStart  := ""
	Local cFim    := ""
	Local lDeb    := .F.
	Local nLinha  := 0

	If (nHandle := FT_FUse( cFile )) == -1
		U_JobCInfo("ORTA023D.PRW", "Falha ao abrir o arquivo '"+AllTrim(cFile)+"'", 1)
		Return()
	Endif

	If "EEVD" $ Upper(cFile)
		lDeb := .T.
	Endif

	FT_FGOTOP()

	While !FT_FEOF()
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		nLinha++
		If lDeb
			If nLinha == 1
				cStart := substr(cBuffer,1,2)
			Else
				If !Empty(cBuffer)
					cFim   := substr(cBuffer,1,2)
				Endif
			Endif
		Else
			If nLinha == 1
				cStart := substr(cBuffer,1,3)
			Else
				If !Empty(cBuffer)
					cFim   := substr(cBuffer,1,3)
				Endif
			Endif
		Endif
		FT_FSKIP()
	End

	If lDeb
		If cStart <> "00" .OR. cFim <> "04"
			SendMail("Arquivo de Débito ("+cFile+") Invalido, favor entrar em contato com a operadora."," liberacao.cartao@ortobom.com.br")
		Endif
	Else
		If cStart <> "002" .OR. cFim <> "028"
			SendMail("Arquivo de Credito ("+cFile+") Invalido, favor entrar em contato com a operadora."," liberacao.cartao@ortobom.com.br")
		Endif
	Endif

	FT_FUSE()
Return

//-------------------------------------------------
Static Function SendMail(cMsg, cTo)
	cServer   := "10.0.100.102"
	cAccount  := "sistema"
	cPassword := "sis7823@w"
	cLog	  := ""

	CONNECT SMTP SERVER cServer ACCOUNT cAccount PASSWORD cPassword Result lOk

	If !lOk
		U_JobCInfo("ORTA023D.PRW", "Erro de Autenticação", 1)
	Endif

	_cBody  := cMsg

	SEND MAIL FROM 'sistema@ortobom.com.br' TO cTo SUBJECT "FALHA DE INTEGRIDADE ARQUIVO REDE" BODY _cBody Result lOk

	If !lOk
		U_JobCInfo("ORTA023D.PRW", "Problemas no envio de email", 1)
	Else
		U_JobCInfo("ORTA023D.PRW", "E-mail Enviado : " + cMsg, 2)
		_cInsReq := " INSERT INTO SIGA.LOGROTINA (UN, USUARIO, DTLOG, HORA, ROTINA, CNT, OBSERV) "
		_cInsReq += " VALUES ('"+cEmpAnt+"','JOB','"+DTOC(dDatabase)+"','"+time()+"','ORTA023D','N','"+cMsg+"')"
		TcSqlExec(_cInsReq)
	EndIf

	DISCONNECT SMTP SERVER
Return


User function ORTA023P()
	Local cQuery:= ""

	cQuery:= "UPDATE SIGA.PA7030
	cQuery+= "   SET PA7_FILIAL = 'DD'
	cQuery+= " WHERE R_E_C_N_O_ IN (SELECT DISTINCT REC
	cQuery+= "                        FROM (SELECT COUNT(*) AS CONTA,
	cQuery+= "                                     PA7_ADM,
	cQuery+= "                                     PA7_ADMORI,
	cQuery+= "                                     PA7_AUTORI,
	cQuery+= "                                     PA7_CARTAO,
	cQuery+= "                                     PA7_PV,
	cQuery+= "                                     PA7_DTVEND,
	cQuery+= "                                     PA7_NOMARQ,
	cQuery+= "                                     PA7_VALOR,
	cQuery+= "                                     MAX(R_E_C_N_O_) AS REC
	cQuery+= "                                FROM SIGA.PA7030
	cQuery+= "                               WHERE PA7_FILIAL = '  '
	cQuery+= "                                 AND D_E_L_E_T_ = ' '
	cQuery+= "                                 AND PA7_AUTORI <> '000000000000'
	cQuery+= "                                 AND PA7_DTVEND BETWEEN
	cQuery+= "                                     TO_CHAR(TO_DATE('"+dtos(ddatabase)+"', 'YYYYMMDD') - 30,
	cQuery+= "                                             'YYYYMMDD') AND
	cQuery+= "                                     TO_CHAR(TO_DATE('"+dtos(ddatabase)+"', 'YYYYMMDD') + 30,
	cQuery+= "                                             'YYYYMMDD')
	cQuery+= "                               GROUP BY PA7_ADM,
	cQuery+= "                                        PA7_ADMORI,
	cQuery+= "                                        PA7_AUTORI,
	cQuery+= "                                        PA7_CARTAO,
	cQuery+= "                                        PA7_PV,
	cQuery+= "                                        PA7_DTVEND,
	cQuery+= "                                        PA7_NOMARQ,
	cQuery+= "                                        PA7_VALOR
	cQuery+= "                              HAVING COUNT(*) > 1))

	If TcSqlExec(cQuery) == 0
		alert("Executada com sucesso")
	Else
		alert("Nao foi possivel executar neste momento")
	Endif

Return


// EXPORTACAO BLU-COBOL
//          1234567890
User Function OTA023KJ(cEmpExec, cFilExec, xParJob)
	//-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
	Local _nX		:= 0
	Local aUnid	:= {}
	Local cCobFileName	:= ""
	Local nHandle2   	:= 00
	Local cLinha		:= ""
	Local cQry			:= ""

	aUnid	:= U_ORTPJOBU(cEmpExec, cFilExec)
	For _nX := 1 To Len(aUnid)

		If Select("SX2") == 0
			OpenSm0()
		Endif
		RPCSetType(3)
		RPCSetEnv(aUnid[_nX][1] , aUnid[_nX][2],,,"FIN",,,,,,)

		U_ORTPJOBM(xParJob)

		U_JobCInfo("ORTA023D.PRW", "INICIADA - Exportacao BLU-Cobol", 2)

		cEmpresa := cEmpAnt

		If cEmpAnt == '18' .AND. cFilAnt == "03"
			cEmpresa := "27"
		ElseIf cEmpAnt == '18' .AND. cFilAnt == "04"
			cEmpresa := "28"
		Endif

		cCobFileName	:= 'COB_'+cEmpresa + '_' + StrTran(DToS(Date()) + "_BLU.CSV", ":", "")

		If (File("\cobol\cobol\regrj\msiga\blu\sigo\" + cCobFileName))
			Return
		EndIf

		nHandle2 := FCreate("\cobol\cobol\regrj\msiga\blu\sigo\" + cCobFileName)

		cLinha:= 'UN;ORIGEM;BLU_ID;BLU_UUID;BLU_UUIDPARC;CHARGE_ID;PAID_AT;RELEASED_AT;GROSS_VALUE;INSTALLMENTS;DT_RECPAR;DT_DEVCOB;DEV_VALUE;NET_VALUE;RATE_VALUE;TAX_RATE;ADVANCES_RATE_VALUE;PAYMENT_COLLECTION_REFERENCE;PAYMENT_PLAN_UUID;PAYMENT_PLAN_INVOICE_NUMBER;CNPJ;STATUS_NOME;CHARGED'
		FWrite(nHandle2, cLinha+Chr(13)+Chr(10))

		cQry	:= "SELECT
		cQry	+= "       UN,
		cQry	+= "       BLU_ID,
		cQry	+= "       BLU_UUID,
		cQry	+= "       RELEASED_AT,
		cQry	+= "       CHARGE_ID,
		cQry	+= "       PAID_AT,
		cQry	+= "       INSTALLMENTS,
		cQry	+= "       GROSS_VALUE,
		cQry	+= "       NET_VALUE,
		cQry	+= "       RATE_VALUE,
		cQry	+= "       TAX_RATE,
		cQry	+= "       ADVANCES_RATE_VALUE AS ARV,
		cQry	+= "       CHARGED,
		cQry	+= "       PAYMENT_COLLECTION_REFERENCE as PCR,
		cQry	+= "       PAYMENT_PLAN_UUID AS PPU,
		cQry	+= "       PAYMENT_PLAN_INVOICE_NUMBER AS PPIN,
		cQry	+= "       ORIGEM,
		cQry	+= "       CNPJ,
		cQry	+= "       DT_RECPAR,
		cQry	+= "       DT_DEVCOB,
		cQry	+= "       DEV_VALUE,
		cQry	+= "       STATUS_NOME,
		cQry	+= "       BLU_UUIDPARC
		cQry	+= "       FROM SIGA.TRANSACAOBLU BLU
		If cEmpAnt == '18' .AND. cFilAnt == "03"
			cQry += " WHERE UN = '27'
		ElseIf cEmpAnt == '18' .AND. cFilAnt == "04"
			cQry += " WHERE UN = '28'
		Else
			cQry += " WHERE UN = '"+cEmpAnt+"'
		Endif
		cQry	+= "       AND TRUNC( TO_DATE(RELEASED_AT, 'YYYYMMDD HH24:MI:SS' ), 'DD') >= TRUNC( SYSDATE-30, 'DD')
		cQry	+= "       ORDER BY CNPJ, TO_DATE(RELEASED_AT, 'YYYYMMDD'), BLU_ID

		U_ORTQUERY(cQry,"OTA023KJ","ORTA023D_OTA023KJ.sql")

		While !OTA023KJ->(EOF())
			cLinha := ""

			cLinha += AllTrim(OTA023KJ->UN)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->ORIGEM)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->BLU_ID)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->BLU_UUID)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->BLU_UUIDPARC)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->CHARGE_ID)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->PAID_AT)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->RELEASED_AT)
			cLinha += ';'
			cLinha += AllTrim(Str(OTA023KJ->GROSS_VALUE))
			cLinha += ';'
			cLinha += AllTrim(Str(OTA023KJ->INSTALLMENTS))
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->DT_RECPAR)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->DT_DEVCOB)
			cLinha += ';'
			cLinha += AllTrim(Str(OTA023KJ->DEV_VALUE))
			cLinha += ';'
			cLinha += AllTrim(Str(OTA023KJ->NET_VALUE))
			cLinha += ';'
			cLinha += AllTrim(Str(OTA023KJ->RATE_VALUE))
			cLinha += ';'
			cLinha += AllTrim(Str(OTA023KJ->TAX_RATE))
			cLinha += ';'
			cLinha += AllTrim(Str(OTA023KJ->ARV))
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->PCR)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->PPU)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->PPIN)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->CNPJ)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->STATUS_NOME)
			cLinha += ';'
			cLinha += AllTrim(OTA023KJ->CHARGED)
			cLinha += ''

			FWrite(nHandle2, cLinha+Chr(13)+Chr(10))
			OTA023KJ->(dbSkip())
		EndDo

		FClose(nHandle2)

		U_JobCInfo("ORTA023D.PRW", "CONCLUIDA - Exportacao BLU-Cobol", 2)

		U_ORTPJOBC()

	Next _nX

Return

// Copia arquivo texto (substitui COPY FILE legado). SMCopy validado + log de erro.
Static Function JMPcp(cOri, cDst)
	Local cDirDst := Left(cDst, RAt("\", cDst) - 1)
	If !ExistDir(cDirDst)
		MakeDir(cDirDst)
	EndIf
	If !SMCopy(cOri, cDst)
		U_JobCInfo("ORTA023D.PRW", "falha ao copiar '" + cOri + "' para '" + cDst + "'", 1)
		Return .F.
	EndIf
Return .T.
// EEVD - movimentacao diaria de debito (RD). CSV via Arruma(). Valores monetarios: /100.
Static Function EEVD()
	Local nMov := 0
	Local nSkip := 0
	_cEmpZF := "  "
	_cFilZF := "  "
	cAdmin   := "19"
	nLeErro  := 0
	FT_FGOTOP()
	While !FT_FEOF()
		cBuffer := StrIConv(AllTrim(FT_FREADLN()),"UTF-8","CP1252")
		Arruma()
		If cCampo01 == "00"
			U_JobCInfo("ORTA023D.PRW", "EEVD header - estab "+cCampo02+" tipo "+cCampo05+" - "+cFile, 2)
			nLeErro := 0
		ElseIf cCampo01 == "011"
			// campos: 02 estab, 03 resumo, 04 data, 05 valor(15,/100), 06 D/C, 07 tipo, 08 descricao, 09 cartao, 10 dt venda, 11 autorizacao, 12 nsu
			cResumo := cCampo03
			dDataven:= Stod(Substr(cCampo10,7,2)+Substr(cCampo10,5,2)+Substr(cCampo10,3,2))
			dDataPg := Stod(Substr(cCampo04,7,2)+Substr(cCampo04,5,2)+Substr(cCampo04,3,2))
			nValbrut:= Val(cCampo05)/100
			nValliq := nValbrut
			nValtx  := 0
			cCartao := cCampo09
			cCodAut := cCampo11
			cNoPOS  := ""
			cTipo   := "CD"
			cParcela:= "01"
			cTotParc:= "01"
			cDescric:= "REDCARD DEBITO EEVD"
			U_JobCInfo("ORTA023D.PRW", "EEVD movimento - resumo "+cResumo+" valor "+AllTrim(Str(nValbrut))+" - "+cFile, 2)
			GeraSZF("A")
			nMov++
			nLeErro := 0
		ElseIf Empty(cBuffer) .Or. Substr(cBuffer,1,1) == "9"
			// trailer/vazio: nao conta erro
		Else
			nSkip++
			U_JobCInfo("ORTA023D.PRW", "EEVD registro tipo "+cCampo01+" ignorado - "+cFile, 2)
			nLeErro := 0
		EndIf
		FT_FSKIP()
	EndDo
	U_JobCInfo("ORTA023D.PRW", "EEVD concluido - "+AllTrim(Str(nMov))+" movimentos, "+AllTrim(Str(nSkip))+" ignorados - "+cFile, 2)
	FT_FUSE()
Return()
