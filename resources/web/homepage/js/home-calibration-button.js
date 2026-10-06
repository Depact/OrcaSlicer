// Homepage calibration button: opens a list of test options with image previews and direction to guide.
// Row index sent to C++ as CalibKind ordinal for MainFrame::run_calibration.
// Loaded after home.js; depends on SendWXMessage and OpenUrlInLocalBrowser from ../include/globalapi.js.

function CloseCalibrationMenu()
{
	$('#cali_hover_panel').hide();
	$('#cali_context_menu').hide();
}

function OnClickCalibration()
{
	if ($('#cali_context_menu').is(':visible')) {
		CloseCalibrationMenu();
		return;
	}
	ShowCalibrationMenu();
}

function ShowCalibrationMenu()
{
	$("#cali_context_menu").offset({top: 10000, left:-10000});
	$('#cali_context_menu').show();

	let MenuWidth = $('#cali_context_menu').width();
	let MenuHeight = $('#cali_context_menu').height();
	let DocumentWidth = $(document).width();
	let DocumentHeight = $(document).height();

	let Trigger = $('#cali_menu_trigger');
	let RealX = Trigger.offset().left;
	let RealY = Trigger.offset().top + Trigger.height() + 4;

	if (RealX + MenuWidth + 24 > DocumentWidth)
		RealX = Math.max(0, DocumentWidth - MenuWidth - 24);
	if (RealY + MenuHeight + 24 > DocumentHeight)
		RealY = Math.max(0, DocumentHeight - MenuHeight - 24);

	$("#cali_context_menu").offset({top: RealY, left: RealX});

	BindCalibrationRowHover();
}

function HideCaliHoverPanel()
{
	$('#cali_hover_panel').hide();
}

function ShowCaliHoverPanel(Row)
{
	let Img = $('#cali_hover_img');
	let Src = $(Row).attr('data-img');
	if (Src == null)
		return;

	let Panel = $('#cali_hover_panel');

	// Show and position before swapping figure to avoid flicker
	Panel.show();
	PlaceCaliHoverPanel(Row);

	if (Img.attr('src') != Src)
	{
		let Preload = new Image();
		Preload.onload = function(){ Img.attr('src', Src).show(); };
		Preload.onerror = function(){ Img.hide(); };
		Preload.src = Src;
	}
	else
	{
		Img.show();
	}

	$('#cali_hover_link').off('click').on('click', function(){
		CloseCalibrationMenu();
		OpenUrlInLocalBrowser($(Row).attr('data-wiki'));
	});
}

function PlaceCaliHoverPanel(Row)
{
	let Panel = $('#cali_hover_panel');
	let MenuBox = $('#cali_context_menu')[0].getBoundingClientRect();
	let RowBox = Row.getBoundingClientRect();
	let PanelW = Panel.outerWidth();
	let PanelH = Panel.outerHeight();
	let DocumentWidth = $(document).width();
	let DocumentHeight = $(document).height();
	let Gap = 10;

	let RealX = MenuBox.right + Gap;
	if (RealX + PanelW + 12 > DocumentWidth)
		RealX = Math.max(0, MenuBox.left - Gap - PanelW);

	let RealY = RowBox.top + RowBox.height / 2 - PanelH / 2;
	RealY = Math.max(0, Math.min(RealY, DocumentHeight - PanelH - 12));

	Panel.offset({top: RealY, left: RealX});
}

function BindCalibrationRowHover()
{
	$('.CaliItem').off('mouseenter.caliHover').on('mouseenter.caliHover', function(){
		ShowCaliHoverPanel(this);
	});

	$('.CaliItem').off('mouseleave.caliHover').on('mouseleave.caliHover', function(){
		let Panel = $('#cali_hover_panel');
		let ToPanel = Panel.is(':visible') && Panel[0].contains(event.relatedTarget);
		let ToMenu = event.relatedTarget && event.relatedTarget.closest &&
			event.relatedTarget.closest('#cali_context_menu');
		if (!ToPanel && !ToMenu)
			HideCaliHoverPanel();
	});
}

function OnSelectCalibrationTest(nIndex)
{
	CloseCalibrationMenu();

	var tSend = {};
	tSend['sequence_id'] = Math.round(new Date() / 1000);
	tSend['command'] = "homepage_calibration_test";
	tSend['data'] = {};
	tSend['data']['kind'] = "" + nIndex;

	SendWXMessage(JSON.stringify(tSend));
}

function OnClickCalibrationGuide()
{
	CloseCalibrationMenu();
	OpenUrlInLocalBrowser("https://www.orcaslicer.com/wiki/guides/calibration_guide");
}