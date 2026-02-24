package tui

import (
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/reflow/wordwrap"

	"github.com/nick/proctmux/internal/config"
	"github.com/nick/proctmux/internal/domain"
)

// Process list (bubbles/list) and filter input (bubbles/textinput)

// colorToLipgloss translates color names and values to lipgloss-compatible color strings
func colorToLipgloss(color string) string {
	if color == "" || color == "none" {
		return ""
	}

	// Map common color names to ANSI color codes
	colorMap := map[string]string{
		"black":   "0",
		"red":     "1",
		"green":   "2",
		"yellow":  "3",
		"blue":    "4",
		"magenta": "5",
		"cyan":    "6",
		"white":   "7",

		// Bright variants
		"brightblack":   "8",
		"brightred":     "9",
		"brightgreen":   "10",
		"brightyellow":  "11",
		"brightblue":    "12",
		"brightmagenta": "13",
		"brightcyan":    "14",
		"brightwhite":   "15",

		// Alternative names
		"gray":       "8",
		"grey":       "8",
		"lightred":   "9",
		"lightgreen": "10",

		// ANSI color names (from prompt_toolkit style)
		"ansiblack":         "0",
		"ansired":           "1",
		"ansigreen":         "2",
		"ansiyellow":        "3",
		"ansiblue":          "4",
		"ansimagenta":       "5",
		"ansicyan":          "6",
		"ansiwhite":         "7",
		"ansibrightblack":   "8",
		"ansibrightred":     "9",
		"ansibrightgreen":   "10",
		"ansibrightyellow":  "11",
		"ansibrightblue":    "12",
		"ansibrightmagenta": "13",
		"ansibrightcyan":    "14",
		"ansibrightwhite":   "15",
		"ansigray":          "8",
		"ansigrey":          "8",
	}

	// Check if it's a named color
	if code, ok := colorMap[strings.ToLower(color)]; ok {
		return code
	}

	// Otherwise, assume it's already a valid color value (hex, ANSI code, etc.)
	return color
}

type processListComponent struct {
	cfg         *config.ProcTmuxConfig
	list        list.Model
	allocHeight int
	ready       bool // true once the list has been constructed
}

type procItem struct{ view *domain.ProcessView }

func (i procItem) Title() string       { return i.view.Label }
func (i procItem) Description() string { return "" }
func (i procItem) FilterValue() string {
	if i.view.Config == nil || len(i.view.Config.Categories) == 0 {
		return i.view.Label
	}
	return i.view.Label + " " + strings.Join(i.view.Config.Categories, ",")
}

type procDelegate struct{ cfg *config.ProcTmuxConfig }

func (d procDelegate) Height() int                               { return 1 }
func (d procDelegate) Spacing() int                              { return 0 }
func (d procDelegate) Update(msg tea.Msg, m *list.Model) tea.Cmd { return nil }
func (d procDelegate) Render(w io.Writer, m list.Model, index int, listItem list.Item) {
	it, ok := listItem.(procItem)
	if !ok || it.view == nil {
		return
	}
	selected := index == m.Index()

	// Set marker and color based on process status using config values
	var marker string
	var markerColor string

	switch it.view.Status {
	case domain.StatusRunning:
		marker = "●"
		markerColor = colorToLipgloss(d.cfg.Style.StatusRunningColor)
	case domain.StatusHalting:
		marker = "◐"
		markerColor = colorToLipgloss(d.cfg.Style.StatusHaltingColor)
	case domain.StatusHalted, domain.StatusExited, domain.StatusUnknown:
		marker = "■"
		markerColor = colorToLipgloss(d.cfg.Style.StatusStoppedColor)
	default:
		marker = "■"
		markerColor = colorToLipgloss(d.cfg.Style.StatusStoppedColor)
	}

	// Create style for the status marker
	markerStyle := lipgloss.NewStyle()
	if markerColor != "" {
		markerStyle = markerStyle.Foreground(lipgloss.Color(markerColor))
	}

	// Pointer for selected item
	pointer := "  "
	if selected {
		pointer = d.cfg.Style.PointerChar + " "
	}

	// Text style for process label
	fg := d.cfg.Style.UnselectedProcessColor
	bg := ""
	if selected {
		fg = d.cfg.Style.SelectedProcessColor
		bg = d.cfg.Style.SelectedProcessBgColor
	}
	style := lipgloss.NewStyle()
	if fg != "" && fg != "none" {
		style = style.Foreground(lipgloss.Color(colorToLipgloss(fg)))
	}
	if bg != "" && bg != "none" {
		style = style.Background(lipgloss.Color(colorToLipgloss(bg)))
	}

	text := it.view.Label
	if d.cfg.Layout.EnableDebugProcessInfo {
		cat := ""
		if it.view.Config != nil && len(it.view.Config.Categories) > 0 {
			cat = " [" + strings.Join(it.view.Config.Categories, ",") + "]"
		}
		text = fmt.Sprintf("%s [%s] PID:%d%s", it.view.Label, it.view.Status.String(), it.view.PID, cat)
	}

	fmt.Fprintf(w, "%s%s %s", pointer, markerStyle.Render(marker), style.Render(text))
}

func (c *processListComponent) ensure() {
	if !c.ready {
		c.list = list.New([]list.Item{}, procDelegate{cfg: c.cfg}, 0, 0)
		c.list.SetShowHelp(false)
		c.list.SetFilteringEnabled(false)
		c.list.SetShowStatusBar(false)
		c.list.SetShowTitle(false)
		c.ready = true
	}
}

func (c *processListComponent) SetConfig(cfg *config.ProcTmuxConfig) {
	c.cfg = cfg
	if c.ready {
		// Update the delegate with the new config without reinitialising the list.
		c.list.SetDelegate(procDelegate{cfg: cfg})
	} else {
		c.ensure()
	}
}
func (c *processListComponent) SetItems(items []*domain.ProcessView) {
	c.ensure()
	li := make([]list.Item, 0, len(items))
	for _, pv := range items {
		li = append(li, procItem{view: pv})
	}
	c.list.SetItems(li)
}
func (c *processListComponent) SetActiveID(id int) {
	c.ensure()
	items := c.list.Items()
	idx := 0
	for i, it := range items {
		pi, ok := it.(procItem)
		if ok && pi.view != nil && pi.view.ID == id {
			idx = i
			break
		}
	}
	c.list.Select(idx)
}
func (c *processListComponent) SetSize(w, h int) {
	c.ensure()
	c.allocHeight = h
	c.list.SetSize(w, h)
}
func (c *processListComponent) View() string {
	c.ensure()
	content := c.list.View()

	// Use MaxHeight to constrain the list if we have allocated height
	// This ensures the list doesn't grow beyond its allocated space
	if c.allocHeight > 0 {
		style := lipgloss.NewStyle().MaxHeight(c.allocHeight)
		return style.Render(content)
	}

	return content
}

type filterComponent struct{ ti textinput.Model }

func newFilterComponent() filterComponent {
	ti := textinput.New()
	ti.Prompt = "Filter: "
	ti.Placeholder = ""
	ti.EchoMode = textinput.EchoNormal
	ti.SetValue("")
	ti.Blur()
	return filterComponent{ti: ti}
}

func (f *filterComponent) SetValue(v string) { f.ti.SetValue(v) }
func (f *filterComponent) SetFocused(on bool) {
	if on {
		f.ti.Focus()
	} else {
		f.ti.Blur()
	}
}
func (f filterComponent) View() string {
	if f.ti.Focused() {
		return f.ti.View()
	}
	return ""
}

// Panels and View

// helpPanelBubbleTea renders help using bubble tea's help component
// Always shows the full help view when visible
// Toggled on/off with '?' keybinding
func (m ClientModel) helpPanelBubbleTea() string {
	if !m.ui.ShowHelp {
		return ""
	}

	// Always show full help
	m.help.ShowAll = true
	helpView := m.help.View(m.keys)

	modeInfo := lipgloss.NewStyle().Faint(true).Render("[Client Mode - Connected to Primary]")

	return lipgloss.JoinVertical(lipgloss.Left, helpView, modeInfo)
}

func messagesPanel(width int, info string, msgs []string) string {
	if info == "" && len(msgs) == 0 {
		return ""
	}

	if width < 1 {
		width = 1
	}

	var parts []string

	if info != "" {
		wrappedInfo := wordwrap.String(info, width)
		infoStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("3")) // yellow
		parts = append(parts, infoStyle.Render(wrappedInfo))
	}

	if len(msgs) > 0 {
		headerStyle := lipgloss.NewStyle().Bold(true)
		parts = append(parts, headerStyle.Render("Messages:"))

		start := 0
		if len(msgs) > 5 {
			start = len(msgs) - 5
		}

		msgStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8")) // gray
		for _, m := range msgs[start:] {
			bullet := wrapBulletLine(m, width)
			parts = append(parts, msgStyle.Render(bullet))
		}
	}

	return lipgloss.JoinVertical(lipgloss.Left, parts...)
}

func wrapBulletLine(text string, width int) string {
	text = strings.TrimSpace(text)
	if text == "" {
		return "- "
	}

	if width <= 2 {
		return "- " + text
	}

	wrapWidth := max(width-2, 1)

	wrapped := wordwrap.String(text, wrapWidth)
	lines := strings.Split(wrapped, "\n")
	if len(lines) == 0 {
		return "- "
	}

	var result []string
	result = append(result, "- "+lines[0])
	for _, line := range lines[1:] {
		result = append(result, "  "+line)
	}

	return strings.Join(result, "\n")
}

func processDescriptionPanel(cfg *config.ProcTmuxConfig, proc *domain.Process, width int) string {
	if cfg.Layout.HideProcessDescriptionPanel {
		return ""
	}
	if proc == nil || proc.Config == nil {
		return ""
	}

	desc := strings.TrimSpace(proc.Config.Description)
	if desc == "" {
		return ""
	}

	if width > 0 {
		desc = wordwrap.String(desc, width)
	}

	descStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("7")). // white/light gray
		Italic(true)

	return descStyle.Render(desc)
}

func (m ClientModel) View() string {
	// Show loading state until first update is received
	if !m.initialized {
		loadingStyle := lipgloss.NewStyle().
			Foreground(lipgloss.Color("6")). // cyan
			Bold(true)

		msg := loadingStyle.Render("Loading process list...")

		if m.termHeight > 0 {
			return lipgloss.PlaceVertical(m.termHeight, lipgloss.Center, msg)
		}
		return msg
	}

	// Build all panels - each component is responsible for its own content
	var panels []string

	now := time.Now()

	panelWidth := m.termWidth
	if panelWidth <= 0 {
		panelWidth = 80
	}

	// Help panel - hidden by default, toggled with '?'
	help := m.helpPanelBubbleTea()
	if help != "" {
		panels = append(panels, help)
	}

	desc := processDescriptionPanel(m.domain.Config, m.domain.GetProcessByID(m.ui.ActiveProcID), panelWidth)
	if desc != "" {
		panels = append(panels, desc)
	}

	visibleMsgs := m.visibleMessages(now)
	msgs := messagesPanel(panelWidth, m.ui.Info, visibleMsgs)
	if msgs != "" {
		panels = append(panels, msgs)
	}

	filter := m.filterUI.View()
	if filter != "" {
		panels = append(panels, filter)
	}

	list := m.procList.View()
	if list != "" {
		panels = append(panels, list)
	}

	// Compose UI using lipgloss - this properly handles spacing and layout
	// Use PlaceVertical to ensure content fills the terminal height
	content := lipgloss.JoinVertical(lipgloss.Left, panels...)

	// If we have a known terminal height, place content to fill the space
	if m.termHeight > 0 {
		return lipgloss.PlaceVertical(m.termHeight, lipgloss.Top, content)
	}

	return content
}
