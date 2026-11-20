/** @type {import('tailwindcss').Config} */
export default {
  content: ['./src/renderer/**/*.{html,ts,tsx}'],
  theme: {
    extend: {
      colors: {
        mb: {
          bg: '#1c1c1e',
          sidebar: '#161618',
          bar: '#141416',
          surface: '#252527',
          line: 'rgba(255,255,255,0.08)',
          hover: 'rgba(255,255,255,0.05)',
          selected: 'rgba(59,130,246,0.14)',
          accent: '#3b82f6',
          text: '#efefef',
          muted: '#888',
          dim: '#555',
          green: '#22c55e',
          red: '#ef4444',
          orange: '#f97316',
        }
      },
      fontFamily: {
        sans: ['"Segoe UI"', 'system-ui', 'sans-serif'],
        mono: ['"Cascadia Code"', '"Cascadia Mono"', 'Consolas', 'monospace']
      }
    }
  },
  plugins: []
}
