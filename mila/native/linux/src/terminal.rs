//! Bounded text renderer for the Linux terminal presentation surface.
//!
//! PTY transport remains owned by the authenticated runtime. This renderer only
//! receives already decoded text, keeps a bounded viewport, and never exposes
//! terminal bytes to GTK or logs.

const MAX_RENDERED_CHARS: usize = 64 * 1024;
const MAX_CHUNK_CHARS: usize = 16 * 1024;
const MAX_COLUMNS: u16 = 512;
const MAX_ROWS: u16 = 512;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RenderError {
    InvalidDimensions,
    ChunkTooLarge,
    UnsupportedControl,
}

/// A bounded terminal viewport suitable for a GTK text surface.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalRenderer {
    columns: u16,
    rows: u16,
    lines: Vec<String>,
    cursor_column: usize,
    rendered_chars: usize,
}

impl TerminalRenderer {
    pub fn new(columns: u16, rows: u16) -> Result<Self, RenderError> {
        if !(1..=MAX_COLUMNS).contains(&columns) || !(1..=MAX_ROWS).contains(&rows) {
            return Err(RenderError::InvalidDimensions);
        }
        Ok(Self {
            columns,
            rows,
            lines: vec![String::new()],
            cursor_column: 0,
            rendered_chars: 0,
        })
    }

    pub const fn columns(&self) -> u16 {
        self.columns
    }

    pub const fn rows(&self) -> u16 {
        self.rows
    }

    pub fn lines(&self) -> &[String] {
        &self.lines
    }

    pub const fn cursor_column(&self) -> usize {
        self.cursor_column
    }

    /// Appends decoded display text while preserving a bounded viewport.
    /// Newline, carriage return, tab and backspace are handled locally;
    /// all other control characters are rejected before they reach GTK.
    pub fn append_text(&mut self, text: &str) -> Result<(), RenderError> {
        if text.chars().count() > MAX_CHUNK_CHARS {
            return Err(RenderError::ChunkTooLarge);
        }
        let mut next = self.clone();
        next.append_text_inner(text)?;
        *self = next;
        Ok(())
    }

    fn append_text_inner(&mut self, text: &str) -> Result<(), RenderError> {
        for character in text.chars() {
            match character {
                '\n' => self.newline(),
                '\r' => self.cursor_column = 0,
                '\t' => {
                    let next = (self.cursor_column / 8 + 1) * 8;
                    self.cursor_column = next.min(self.columns as usize);
                }
                '\u{8}' => self.cursor_column = self.cursor_column.saturating_sub(1),
                character if character.is_control() => return Err(RenderError::UnsupportedControl),
                character => self.append_character(character),
            }
        }
        Ok(())
    }

    fn append_character(&mut self, character: char) {
        if self.rendered_chars >= MAX_RENDERED_CHARS {
            return;
        }
        if self.cursor_column >= self.columns as usize {
            self.newline();
        }
        let line = self.lines.last_mut().expect("renderer always has one line");
        let byte_offset = line
            .char_indices()
            .nth(self.cursor_column)
            .map_or(line.len(), |(offset, _)| offset);
        if self.cursor_column < line.chars().count() {
            let end = line
                .char_indices()
                .nth(self.cursor_column + 1)
                .map_or(line.len(), |(offset, _)| offset);
            line.replace_range(byte_offset..end, &character.to_string());
        } else {
            line.push(character);
        }
        self.cursor_column += 1;
        self.rendered_chars += 1;
    }

    fn newline(&mut self) {
        self.lines.push(String::new());
        self.cursor_column = 0;
        while self.lines.len() > self.rows as usize {
            let removed = self.lines.remove(0);
            self.rendered_chars = self.rendered_chars.saturating_sub(removed.chars().count());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{RenderError, TerminalRenderer};

    #[test]
    fn renders_bounded_text_and_control_navigation() {
        let mut renderer = TerminalRenderer::new(8, 2).expect("dimensions");
        renderer.append_text("hello\nworld\rX").expect("text");
        assert_eq!(renderer.lines(), &["hello".to_owned(), "Xorld".to_owned()]);
        assert_eq!(renderer.cursor_column(), 1);
        renderer.append_text("\tZ").expect("tab");
        assert_eq!(renderer.lines(), &["Xorld".to_owned(), "Z".to_owned()]);
        assert_eq!(renderer.cursor_column(), 1);
    }

    #[test]
    fn rejects_unsafe_controls_and_unbounded_chunks() {
        let mut renderer = TerminalRenderer::new(80, 24).expect("dimensions");
        assert_eq!(
            renderer.append_text("bad\u{1b}[2J"),
            Err(RenderError::UnsupportedControl)
        );
        assert_eq!(
            renderer.append_text(&"x".repeat(16 * 1024 + 1)),
            Err(RenderError::ChunkTooLarge)
        );
        assert!(TerminalRenderer::new(0, 24).is_err());
    }
}
